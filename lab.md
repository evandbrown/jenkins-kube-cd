# Lab: Build a Continuouso Delivery Pipeline with Jenkins and Kubernetes

## Prerequisites
1. A GitHub account
1. A Google Cloud Platform Account

## Prework
1. Create a new Google Cloud Platform project: [https://console.developers.google.com/project](https://console.developers.google.com/project)
1. Enable the **Google Container Engine** and **Google Compute Engine** APIs
1. Install `gcloud`: [https://cloud.google.com/sdk/](https://cloud.google.com/sdk/)
1. Configure your project and zone: `gcloud config set project YOUR_PROJECT ; gcloud config set compute/zone us-central1-f`
1. Enable `kubectl`: `gcloud components update kubectl`

##  Create a Kubernetes Cluster
You'll use Google Container Engine to create and manage your Kubernetes cluster. Start by setting an env var with the cluster name, then provisioning it with `gcloud`:


```shell
$ export CLUSTER_NAME=yourclustername
$ gcloud container clusters create ${CLUSTER_NAME} \
--scopes "https://www.googleapis.com/auth/projecthosting,https://www.googleapis.com/auth/devstorage.full_control,\
https://www.googleapis.com/auth/monitoring,\
https://www.googleapis.com/auth/logging.write,\
https://www.googleapis.com/auth/compute,\
https://www.googleapis.com/auth/cloud-platform"
```

Now you can confirm that the cluster is running and `kubectl` is working by listing pods:

```shell
$ kubectl get pods
```

An empty response is what you expect here.

### Create a Jenkins Replication Controller and Service
Here you'll create a Replication Controller running a Jenkins image, and then a service that will route requests to the controller.

The Jenkins Replication Controller is defined in `jenkins.yaml` with the following content:

```yaml
kind: ReplicationController
apiVersion: v1
metadata:
  name: jenkins-leader
  labels:
    name: jenkins
    role: leader
spec:
  replicas: 1
  selector:
    name: jenkins
    role: leader
  template:
    metadata:
      name: jenkins-leader
      labels:
        name: jenkins
        role: leader
    spec:
      containers:
      - name: jenkins
        image: gcr.io/cloud-solutions-images/jenkins-gcp-leader:master-5ca73a6
        command:
        - /usr/local/bin/start.sh
        env:
        - name: GCS_RESTORE_URL
          value: DISABLED
        ports:
        - name: jenkins-http
          containerPort: 8080
        - name: jenkins-disco
          containerPort: 50000
```

Next, create the controller and confirm a pod was scheduled:

```shell
$ kubectl create -f jenkins.yaml
replicationcontrollers/jenkins-leader

$ kubectl get pods
NAME                   READY     STATUS    RESTARTS   AGE
jenkins-leader-to8xg   0/1       Pending   0          30s
```

Now, deploy the Jenkins Service found in `service_jenkins.yaml` with the following contents:

```yaml
kind: Service
apiVersion: v1
metadata:
  name: jenkins
  labels:
    name: jenkins
    role: frontend
spec:
  ports:
  - name: ui
    port: 8080
    targetPort: jenkins-http
    protocol: TCP
  - name: discovery
    port: 50000
    targetPort: jenkins-disco
    protocol: TCP
  selector:
    name: jenkins
    role: leader
```

Create the service:

```shell
$ kubectl create -f service_jenkins.yaml
...
```

Notice that this service exposes ports `8080` and `50000` for any pods that match the `selector`. This will expose the Jenkins web UI and builder/agent registration ports within the Kubernetes cluster, but does not make them available to the public Internet. Although you could expose port `8080` to the public Internet, Kubernetes makes it simple to use nginx as a reverse proxy, providying basic authentication (and optional SSL termination). Configure that in the next section.

### Create a build agent replication controller
Now that you're running Jenkins, you'll want to run some workers that can do the build jobs assigned by Jenkins. These workers will be Kubernetes pods managed by a replication controller. The pods will be configured to have access to the Docker service on the node they're schedule on. This will allow Jenkins build jobs to be defined as Docker containers, which is super powerful and flexible.

The build agent Replication Controller is defined in `build_agent.yaml` with the following content:

```yaml
kind: ReplicationController
apiVersion: v1
metadata:
  name: jenkins-builder
  labels:
    name: jenkins
    role: agent
    labels: docker
spec:
  replicas: 1
  selector:
    name: jenkins
    role: agent
    labels: docker
  template:
    metadata:
      name: jenkins-builder
      labels:
        name: jenkins
        role: agent
        labels: docker
    spec:
      containers:
      - name: jenkins-builder
        image: gcr.io/cloud-solutions-images/jenkins-packer-agent:master-1f6b3f6
        command:
        - sh
        - -c
        - /usr/local/bin/jenkins-docker-supervisor.sh -master http://$JENKINS_SERVICE_HOST:$JENKINS_SERVICE_PORT_UI -tunnel $JENKINS_SERVICE_HOST:$JENKINS_SERVICE_PORT_DISCOVERY -executors 1 -labels docker
        env:
        - name: HOME
          value: /home/jenkins-agent
        volumeMounts:
          - mountPath: /home/jenkins-agent
            name: jenkins
          - mountPath: /var/lib/docker
            name: docker-lib
          - mountPath: /var/run/docker.sock
            name: docker-sock
          - mountPath: /usr/bin/docker
            name: docker-bin
          - mountPath: /tmp
            name: docker-tmp
      volumes:
        - name: jenkins
          hostPath:
            path: /home/jenkins-agent
        - name: docker-lib
          hostPath:
            path: /var/lib/docker
        - name: docker-sock
          hostPath:
            path: /var/run/docker.sock
        - name: docker-bin
          hostPath:
            path: /usr/bin/docker
        - name: docker-tmp
          hostPath:
            path: /tmp
```

Next, create the controller and confirm a pod was scheduled:

```shell
$ kubectl create -f build_agent.yaml
replicationcontrollers/jenkins-builder

$ kubectl get pods
NAME                   READY     STATUS    RESTARTS   AGE
jenkins-builder-9zttr   0/1       Pending   0          23s
jenkins-leader-to8xg    1/1       Running   0          4h 
```

Resize the build agent replication controller to contain 5 pods:

```shell
$ kubectl scale rc/jenkins-builder --replicas=5
```

Use `kubectl` to verify that 5 pods are running.

### Create a Nginx Replication Controller and Service
The Nginx reverse proxy will be deployed (like the Jenkins server) as a replication controller with a service. The service will have a public load balancer associated.

The nginx Replication Controller is defined in `proxy.yaml` with the following contents:

```yaml
kind: ReplicationController
apiVersion: v1
metadata:
  name: nginx-ssl-proxy
  labels:
    name: nginx
    role: ssl-proxy
spec:
  replicas: 1
  selector:
    name: nginx
    role: ssl-proxy
  template:
    metadata:
      name: nginx-ssl-proxy
      labels:
        name: nginx
        role: ssl-proxy
    spec:
      containers:
      - name: nginx-ssl-proxy
        image: gcr.io/cloud-solutions-images/nginx-ssl-proxy:master-cc00da0 
        command:
        - /bin/bash
        - /usr/bin/start.sh
        env:
        - name: SERVICE_HOST_ENV_NAME
          value: JENKINS_SERVICE_HOST
        - name: SERVICE_PORT_ENV_NAME
          value: JENKINS_SERVICE_PORT_UI
        ports:
        - name: ssl-proxy-http
          containerPort: 80
        - name: ssl-proxy-https
          containerPort: 443
```

Deploy the proxy to Kubernetes:

```shell
$ kubectl create -f proxy.yaml
...
```

Now, deploy the proxy Service found in `service_proxy.yaml` with the following contents:

```yaml
kind: Service
apiVersion: v1
metadata:
  name: nginx-ssl-proxy
  labels:
    name: nginx
    role: ssl-proxy
spec:
  ports:
  - name: https
    port: 443
    targetPort: ssl-proxy-https
    protocol: TCP
  - name: http
    port: 80
    targetPort: ssl-proxy-http
    protocol: TCP
  selector:
    name: nginx
    role: ssl-proxy
  type: LoadBalancer
```

Finally, deploy the service that will expose the Nginx proxy to the Internet:

```shell
kubectl create -f service_proxy.yaml
...
```

Before you can use the service, you need to open firewall ports on the cluster VMs:

```shell
$ gcloud compute instances list \
  -r "^gke-${CLUSTER_NAME}.*node.*$" \
  | tail -n +2 \
  | cut -f1 -d' ' \
  | xargs -L 1 -I '{}' gcloud compute instances add-tags {} --tags gke-${CLUSTER_NAME}-node

$ gcloud compute firewall-rules create ${CLUSTER_NAME}-jenkins-swarm-internal \
  --allow TCP:50000,TCP:8080 \
  --source-tags gke-${CLUSTER_NAME}-node \
  --target-tags gke-${CLUSTER_NAME}-node

$ gcloud compute firewall-rules create ${CLUSTER_NAME}-jenkins-web-public \
  --allow TCP:80,TCP:443 \
  --source-ranges 0.0.0.0/0 \
  --target-tags gke-${CLUSTER_NAME}-node
```

Now find the public IP address of your proxy service and open it in your web browser:

```shell
$ kubectl get service/nginx-ssl-proxy
NAME              LABELS                      SELECTOR                    IP(S)             PORT(S)
nginx-ssl-proxy   name=nginx,role=ssl-proxy   name=nginx,role=ssl-proxy   10.95.241.75      443/TCP
                                                                          173.255.118.210   80/TCP
```

Spend a few minutes poking around Jenkins. You'll configure a build shortly...

### Your progress, and what's next
You've got a Kubernetes cluster managed by Google Container Engine. You've deployed:

* a Jenkins replication controller
* a (non-public) service that exposes Jenkins 
* a Nginx reverse-proxy replication controller that routes to the Jenkins service
* a public service that exposes Nginx

You have the tools to build a continuous delivery pipeline. Now you need a sample app to deliver continuously.

## The sample app
You'll use a very simple sample application - `gceme` - as the basis for your CD pipeline. `gceme` is written in Go. When you run the `gceme` binary on a GCE instance, it displays the instance's metadata in a pretty card:

![](img/info_card.png)

The binary supports two modes of operation, designed to mimic a microservice. In backend mode, `gceme` will listen on a port (8080 by default) and return GCE instance metadata as JSON, with content-type=application/json. In frontend mode, `gceme` will query a backend `gceme` service and render that JSON in the UI you saw above. It looks roughly like this:

```
-----------      ------------      ~~~~~~~~~~~~        -----------
|         |      |          |      |          |        |         |
|  user   | ---> |   gceme  | ---> | lb/proxy | -----> |  gceme  |
|(browser)|      |(frontend)|      |(optional)|   |    |(backend)|
|         |      |          |      |          |   |    |         |
-----------      ------------      ~~~~~~~~~~~~   |    -----------
                                                  |    -----------
                                                  |    |         |
                                                  |--> |  gceme  |
                                                       |(backend)|
                                                       |         |
                                                       -----------
```

Run the app on your workstation:

1. Download `gceme` for [Mac](https://storage.googleapis.com/evandbrown17/darwin/gceme) or [Linux](https://storage.googleapis.com/evandbrown17/linux/gceme) and `chmod +x` once you have it

1. Run a backend on 8181:
        ./gceme -port=8181 &

1. Run a frontend on 8080 that connects to the backend:
        ./gceme -frontend=true -backend-service=http://localhost:8181 -port=8080 &

1. Open your browser to `localhost:8080` or `curl localhost:8080` to confirm the service is working.

### Fork and clone the app 

1. Open the `gceme` repo in your browser: [https://github.com/evandbrown/gceme](https://github.com/evandbrown/gceme)

1. Click the `Fork` button to make a copy of the repository in your GitHub account

1. Clone the repository to your laptop. If you're familiar with Go and have your Go dev environment configured, you can clone the repo to `$GOPATH/src/github.com/yourusername/gceme` and build/run it locally. Totally optional

## Create a pipeline
You'll now use Jenkins to define and run a pipeline that will test, build, and deploy your copy of `gceme` to your Kubernetes cluster. You'll approach this in phases. Let's get started with the first.

### Phase 1: Create a workflow project
This lab uses [Jenkins Workflow](TODO) to define builds as groovy scripts. Navigate to your Jenkins UI and follow these steps to configure a workflow project (hot top: you can find the IP address of your Jenkins install with `kubectl get service/nginx-ssl-proxy`):

1. Click the **New Item** link in the left nav

1. Name the project **gceme**, choose the **Workflow** option, then click `OK`

1. Under **Build Triggers** choose **Poll SCM** and enter `H/1 * * * *` This will have Jenkins poll GitHub every minute looking for changes.

1. Under **Workflow**, choose **Groovy CPS DSL from SCM**

  * Choose **Git** in the **SCM** child option
  * Paste the **HTTPS clone URL** of your GitHub repository into the **Repository URL** field. You can find this value on your GitHub page in the right column:
  
    ![](img/clone_url.png)

  * Your repo should be public; no need to choose credentials
  * Click `Save`

1. Click the `Build Now` button in the left column and watch your build crash and burn.

> ### **FAQ**
> 
> **Why did my build crash and burn?**
>> The job you just created expects the SCM repo it's polling (i.e., your `gceme` repo on GitHub) to have a special `flow.groovy` script that defines how to build/test/deploy the project. Your repo doesn't have that file yet. Hence the crashing and the burning.
>
> **How do I prevent the crashing and the burning?**
>> See Phase 2 below...

### Phase 2: Create a workflow script to pass the build
Make the build pass by adding a simple valid `flow.groovy` script to your `gceme` repo. The file should be in your repo's root and have the following contents:

```groovy
node('docker') {
  sh "echo success"
}
```

`git add flow.groovy`, then `git commit`, and finally `git push origin master` to push your changes to GitHub.

Wait for the build to trigger (~1 minute), or click `Build Now` in the Jenkins UI to start it immediately.

### Phase 2: Modify flow.groovy to bulid and test the app
Modify your `flow.groovy` script so it contains the following (**note**: replace the git repository url with your own):

```groovy
node('docker') {
  docker.image('golang:1.5.1').inside('-v /home/jenkins-agent/workspace/$JOB_NAME:/usr/src/JOB_NAME -w /usr/src/JOB_NAME') {
    git 'https://github.com/evandbrown/gceme.git'
    sh 'go get -d -v'
    sh 'go test'
  }
}
```

Commit and push your changes to GitHub and trigger the build again. 


