# Server Backup and Restore

The system is designed such that it can be recovered from backup in the event of server failure. The integrated backup mechanism requires a shared folder served by another machine. A runbook is included for setting up a shared Linux SMB server with corresponding client configuration on the camera host with appropriate file permissions.

## Recovery Procedure

1. ### Build out the HTTP Services 

    The HTTP Services are not restored from backup file, rather they are built out as new. This is a relatively lightweight activity for the agent and removes ambiguity that might otherwise cause confusion with respect to camera IP settings changed from previous iterations of DHCP assignment. From the main README.md of the repository, `Building the Server`, follow Steps 1 and 2. This will construct the system core upon which Encryption and Authentication layers can be added.

2. ### Recover GPG key

    Follow the instructions in GPG_KEY.md `Recovery` section.

3. ### Recover CA Certificate

    Follow the instructions in CREATE_CA_CERT.md `Recovery` section.

4. ### Generate Site Certificate

    Execute the full runbooks SITE_CERT.md and CA_DISTRIBUTE to re-create the nginx configuration using a newly signed site certificate.

5. ### Restore the Authorization Server

    Follow the instructions in KEYCLOAK_BACKUP `Restore from checkpoint` section to complete the recovery.