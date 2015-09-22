#!/bin/bash
apt-get upgrade -y
apt-get install -y git

# Configure gcloud
gcloud components update kubectl --quiet
ln -s /usr/local/share/google/google-cloud-sdk/bin/kubectl /usr/local/bin/kubectl

cat <<"EOF" > /etc/profile.d/gtc.sh
if [ ! -f "$HOME/.gtcinit" ]; then
  echo "INITIALIZING INSTANCE FOR GTC LAB"
  gcloud config set compute/zone us-central1-f

  # Make project dir
  if [ ! -d "$HOME/gtc" ]; then
    mkdir -p $HOME/gtc 
  fi

  # Clone jenkins-kube-cd
  if [ ! -d "$HOME/gtc/jenkins-kube-cd" ]; then
    cd $HOME/gtc
    git clone https://github.com/evandbrown/jenkins-kube-cd.git
  fi
  touch $HOME/.gtcinit
fi
EOF
