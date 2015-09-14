# Lab: Build a Continuouso Delivery Pipeline with Jenkins and Kubernetes

## Prerequisites
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

## Create a Jenkins Replication Controller and Service
Here you'll create a Replication Controller running a Jenkins image, and then a service that will route requests to the controller.

Start by creating a file called `jenkins.yaml` with the following content:

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

Now, create the file `service_jenkins.yaml` and paste the following contents:

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

## Create a Nginx Replication Controller and Service
The Nginx reverse proxy will be deployed (like the Jenkins server) as a replication controller with a service. The service will have a public load balancer associated.

Create `proxy.yaml` with the following contents:

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

Now, create the file `service_proxy.yaml` with the following contents:

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
