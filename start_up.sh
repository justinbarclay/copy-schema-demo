#!/bin/bash

docker build -t emacs .
docker-compose run emacs sh
