#! /bin/bash
gcloud container clusters create gtc \
  --scopes https://www.googleapis.com/auth/cloud-platform

kubectl create -f kubernetes/jenkins/jenkins.yaml
kubectl create -f kubernetes/jenkins/service_jenkins.yaml
kubectl create -f kubernetes/jenkins/build_agent.yaml
kubectl scale rc/jenkins-builder --replicas=5
kubectl create -f kubernetes/jenkins/ssl_secrets.yaml
kubectl create -f kubernetes/jenkins/proxy.yaml
kubectl create -f kubernetes/jenkins/service_proxy.yaml
