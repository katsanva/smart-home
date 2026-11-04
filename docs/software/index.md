# Introduction

This page describes my system setup. Here you can find software I rely on for running my smart home system.

## Debian

The Raspberry Pi media host runs [Debian 13](https://www.debian.org/) (ARM64). See [Raspberry Pi media host](raspberry-pi.md).

## [Docker](https://www.docker.com/)

I use [Docker](https://www.docker.com/) for managing all containers in my smart home.

Docker allows to encapsulate everything related to a single service within a container. This approach helps to maintain host system clean and manage (start, stop, update and delete) every container separately.

### Enabling hardware acceleration

## smart-home CLI

This is just a bash script I wrote for personal need. You can [find it here](https://github.com/denysdovhan/smart-home/blob/master/bin/smart-home).

This performs typical tasks I do in my smart home, like bootstraping, controlling server, updating, etc.
