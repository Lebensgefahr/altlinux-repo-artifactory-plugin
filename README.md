# Artifactory plugin to create Altlinux repository metadata.

* [Installation](#installation)
* [Usage](#usage)
* [Description](#description)

## Installation

Copy storagePlugin.groovy into /var/opt/jfrog/artifactory/etc/artifactory/plugins/ and run

```
curl -u admin:password -X POST https://artifactory.host/artifactory/api/plugins/reload

```
* Copy `/usr/bin/genpkglist` binary from apt-repo-tools into `/var/opt/jfrog/artifactory/custom/bin/`
* Copy genmetadata script into `/var/opt/jfrog/artifactory/custom/bin/`
* Copy all libraries linked with genpkglist into `/var/opt/jfrog/artifactory/custom/lib`

## Usage

Create repository
```
curl -u admin:password -X PUT \
     -H "Content-Type: application/json" \
     -d '{"rclass":"local", "repoLayoutRef":"simple-default", "packageType":"generic"}' \
     'https://artifactory.host/artifactory/api/repositories/repository'
```
Upload package
```
curl -s -u admin:password -T sample.rpm 'https://artifactory.host/artifactory/repository/altlinux/p8/community/noarch/RPMS.classic/'
```

## Description

After package uploading plugin creates local directories in /var/opt/jfrog/artifactory to process it with genpkglist.
For the sample repository described in the usage section directories structures will be:
```
repository/
└── altlinux
    └── p8
        └── community
            └── noarch
                ├── base
                │   ├── pkglist.classic
                │   ├── pkglist.classic.bz2
                │   ├── pkglist.classic.xz
                │   ├── release
                │   └── release.classic
                └── RPMS.classic
                    └── sample.rpm

```
Repository path `repository:/altlinux/p8/community/noarch/RPMS.classic/sample.rpm` will be transformed into `/var/opt/jfrog/artifactory/repository/altlinux/p8/community/noarch/RPMS.classic/sample.rpm`

After metadata files are generated successfully package file will be removed. Other files will be kept for the repository lifetime. 
In fact all the files except pkglist.classic in the example are not needed and will be overwritten at the next package upload. 
The pkglist.classic is the main file because it has all package records uploaded before. It has its copy in filestore. 

Plugin will create directoy base, generate metadata files in it and deploy it in artifactory. Plugin is compatible with simultaneous packages uploading. 
But it uses lock for the thread to prevent concurrence changes in pkglist file. 
For that reason original genbasedir utility is inapplicable because it overwrites pkglist file every execution and all repository packages should be available. 
In case of plugin using it only appends newly uploaded packages to the already existed pkglist. 

If package with the same file name is already in artifactory it will answer with 409 code. 
It is not possible to load package with the same name twice to prevent duplicates in pkglist. 
On every error occured during copying from filestore, generating metadata or deploy, it will cancel package uploading and return 500 error. 
Plugin works for the path which contains directory with name "altlinux" only.
Due to limitation of genpkglist tool it is not available to delete package from the already generated metadata file. For removing one file whole repository should be processed again except the removed file. When file is removed plugin locks metadata file and starts processing files from repository one by one until it's done.
