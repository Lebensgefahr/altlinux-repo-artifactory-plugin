/*
 * Artifactory plugin for creating Altlinux repository
 */

import java.nio.file.Files
import org.artifactory.repo.RepoPath
import org.artifactory.repo.Repositories
import org.artifactory.repo.RepoPathFactory
import java.util.concurrent.locks.ReentrantLock
import org.artifactory.exception.CancelException

ReentrantLock lock = new ReentrantLock();

storage {
    // Return 409 if file is already exists in repository.
    // genpkglist do not process duplicates, so it can't be used for editing, removing or quering
    // so this check is needed to be sure that there is only one record for one file in it
    beforeCreate { item -> 
    	if (item.repoPath.path.contains("altlinux")) {
	    if (item.repoPath.isFile() && item.repoPath.path.endsWith(".rpm")) {
	    
                def sha1 = item.sha1
                if (sha1 != null) {
                    throw new CancelException("Package with the name " + item.name + " already exists" ,409);
                }
	    }
	}
    }

    afterCreate { item ->

    	if (item.repoPath.path.contains("altlinux")) {
	    if (item.repoPath.isFile() && item.repoPath.path.endsWith(".rpm")) {

		def String sha1 = item.sha1
		// Artifactory filestore path where file could be found as file on disk
		// For example: /var/opt/jfrog/artifactory/data/artifactory/filestore/03/03b3124fe5d38900d2cc78cf3a3f7f367e38f75e
	        def File filestoreDir = new File(ctx.artifactoryHome.dataDir, 'filestore')
		def File packageDirInFilestore = new File(filestoreDir, sha1.substring(0, 2))
		def File packageFileInFilestore = new File(packageDirInFilestore, sha1)

		// Path to save packages for packagelist generating on the filesystem
    		def File packageFile = new File (item.repoPath.repoKey, item.repoPath.path)
		def File rpmsDir = packageFile.getParentFile()
		def File rootDir = rpmsDir.getParentFile()
		def File baseDir = new File (rootDir, 'base')
		def String repoName = rpmsDir.getName().replaceAll('RPMS.', '')
		
		// Path to the pkglist in the repository (not on the filesystem)
		def File rootDirInRepo = new File (item.repoPath.path).getParentFile().getParentFile()
		def File baseDirInRepo = new File(rootDirInRepo, 'base')

		lock.lock()	

		try {
		    // Create base directory
		    baseDir.mkdirs()
		    
		    // Install package file from filestore to the directory wich will be used as dir for genpkglist
		    install(packageFileInFilestore.toString(), packageFile.toString())

		    log.info("Starting to calculate Rpm metadata for " + item.repoPath.repoKey + ':' + rootDirInRepo)
		    genmetadata(rootDir.getAbsolutePath(), repoName)
    
                    // Deploy all generated files to artifactory
		    baseDir.eachFile {
			def InputStream fileAsInputStream = new File (it.getAbsolutePath()).newInputStream()
			def File fileRepoPath = new File (baseDirInRepo, it.getName())

			if(!deployRepoMetadata(item.repoPath.repoKey, fileRepoPath, fileAsInputStream)) {
			    throw new Exception ("Can't deploy " + fileRepoPath + " for package " + item.name)
			}
		    }

		} catch(Exception e) {
                    throw new CancelException("ERROR: [" + item.name + "] " + e ,500);
		} finally {
                    // Remove rpm package
		    packageFile.delete()
    		    lock.unlock()		    
	    	}
	    }
	}
    }
}

def boolean install (String sourceFile, String destinationFile) {
    
    def installCmd = ExecuteConstants.installCommand.replace('{source}', sourceFile)
    installCmd = installCmd.replace('{destination}', destinationFile)
    execLn = installCmd.execute()
    if (execLn.waitFor() != 0) {
	throw new Exception("Non zero status returned: " + installCmd);
    }
}

def boolean genmetadata (String packageDir, String repositoryName) {

    def genmetadataCmd = ExecuteConstants.genmetadataCommand.replace('{pkgDir}', packageDir)
    genmetadataCmd = genmetadataCmd.replace('{repoName}', repositoryName)

    execLn = genmetadataCmd.execute()
    if (execLn.waitFor() != 0) {
	throw new Exception("Non zero status returned: " + genmetadataCmd);
    }
}

def boolean deployRepoMetadata(String repoKey, File deployPath, InputStream binary) {

    def String targetRepoKey = repoKey
    def String targetPath = deployPath
    
    def RepoPath deployRepoPath = RepoPathFactory.create(targetRepoKey, targetPath)
    repositories.deploy(deployRepoPath, binary)
}

class ExecuteConstants {
    static String installCommand = 'install -D {source} {destination}'
    static String genmetadataCommand = '/var/opt/jfrog/artifactory/custom/bin/genmetadata {pkgDir} {repoName}'
}
