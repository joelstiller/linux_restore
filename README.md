# linux_restore
Linux restore script written in perl, using TSM backup.

The concept here is you embed the linux restore script within a boot image that you distrbute using a PXE boot server. The script is designed to work with IBM's TSM backup client, and has some settings such as file system sizes you may wish to change if you ever decide to use this. 
