#!/bin/bash

# Install tools
sudo snap install helix --classic
sudo snap install firefox

# Clone thorium
git clone https://github.com/konungre/thorium.git

# Docker login
docker login
cp ~/.docker/config.json ~/thorium/minithor/.dockerconfigjson
