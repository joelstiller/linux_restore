#!/usr/bin/perl -w -I./
##############################################################################
## Program Name: remote_restore_linux.pl                                    ##
## Author:       Joel Stiller                                               ##
## Date Written: 01/22/10                                                   ##
## Environment:  This script works on Linux.                                ##
## Description:  This script is designed to be run after booting from the   ##
## build server DR image to automagically recover your system!              ##
## Example: ./restore_linux.pl                                              ##
## Version: 2.0                                                             ##
############################################################################## 
## CHANGELOG
## 

use Data::Dumper;
use strict;
use Parallel::ForkManager;
use File::Read;
use Term::UI;
use Term::ReadLine;
use Term::ReadKey;

#Gobal Variables.

$SIG{INT} = \&NoNuke;
my %server_info = (); #---This hash runs the show, all data is stored here.
my $sysinfo_data = (); #--- This is a ref to an AoH it stores the collected data from the sysinfo.html
my @fstab_ary2 = ();   #--- This global is used to preserve mount order. Without it you have issues.
my %netmask_hash = (  #---This was needed to for the nmap sweep.

    '240.0.0.0'             => '/4', 
    '248.0.0.0'             => '/5', 
    '252.0.0.0'             => '/6', 
    '254.0.0.0'             => '/7', 
    '255.0.0.0'             => '/8', 
    '255.128.0.0'           => '/9', 
    '255.192.0.0'           => '/10', 
    '255.224.0.0'           => '/11', 
    '255.240.0.0'           => '/12', 
    '255.248.0.0'           => '/13', 
    '255.252.0.0'           => '/14', 
    '255.254.0.0'           => '/15', 
    '255.255.0.0'           => '/16', 
    '255.255.128.0'         => '/17', 
    '255.255.192.0'         => '/18', 
    '255.255.224.0'         => '/19', 
    '255.255.240.0'         => '/20', 
    '255.255.248.0'         => '/21', 
    '255.255.252.0'         => '/22', 
    '255.255.254.0'         => '/23', 
    '255.255.255.0'         => '/24', 
    '255.255.255.128'       => '/25', 
    '255.255.255.192'       => '/26', 
    '255.255.255.224'       => '/27', 
    '255.255.255.240'       => '/28', 
    '255.255.255.248'       => '/29', 
    '255.255.255.252'       => '/30', 
);

## This has is used to store known TSM exit codes.
$server_info{TSM}->{exit_codes} = {
    '0'      => 'Successful',
    '4'      => 'Successful - Some Files skipped',
    '8'      => 'Successful - Check dsmerror.log',
    '12'    => 'Failed - Check dsmerror.log',
    '1024' => 'Successful - Some Files skipped',
    '3072' => 'No Backup of this file system',
};

    
# Moving all functions to start from here to allow easier following of the code.
&disclaim; # Prints opening information.
&LoadTsmOptions; # This loads the TSM files dsm.sys and dsm.opt
&FindHardware; # Finds the Hard disk and network cards.
&TextQuestions; # This sub will replace all question subs.
&NetSetup; # Configures networks cards based on the questions answered.
&FindTsmServers; # Uses nmap to search for the proper TSM server.
&recap; #<- Calls a sub called do_work. See do_work.

# do_work:Calls other subs, called by &recap.
# Desrc: This sub is used to maintain order of procedure. Called by &recap
# Ex: &do_work --> &part_disk,&restore_root,&lvm_create,&restore,&setup_grub
# &enable_swap,&chg_root,&finish_print.
#------------------------------------------------------------------------------#

sub DoWork {
    &RestoreSysinfo; #Restores sysinfo script data.
    &GetSysinfo; # Collects the data from the sysinfo script -> @sysinfo_data
    &PartDisk; # Partitions Disk 2GB root, 2GB swap, everything else LVM.
    &RestoreRoot; # Restores the / filesystem, and the sysinfo file.
    &LvmCreate; # Recreates the LVMs using info from the sysinfo file.
    &FsToRestore; # Collects the LVM names to be restored.
    &getTotalFiles; # Collects backup info.
    &RestoreLvms; # Performs the restore process on the LVMs.
    &FinalizeDisk; # Configures Grub, and the boot record.
    &FindMismatch; # Checks to see if the hardware type changed.
    if ( $server_info{hwtype}->{mismatch} eq "yes" ) {
        &FixMismatch; # Fixes /etc/fstab and other files if hardware type changed.
    }
    &FinishPrint; # Prints out the completed message.
}

##### -----Only Sub's below this point. All work is completed above.

# FindHardware: Finds local hard disk, and network cards. 
# Ex: &find_hardware --> $server_info{disk},$server_info{network}
#------------------------------------------------------------------------------#
sub FindHardware
{
    #Finding Harddisk
    print "Finding hardisks.....\n";
    my @dev_info = `cat /proc/partitions | grep -v loop`;
    foreach my $dev_info ( @dev_info ) {
        if ( $dev_info =~ m{\s+(\d+)\s+(\d+)\s+(\d+)\s+([a-zA-Z]+)} ) {
            my $dev_name = $4;
            next if ( $3 < "3000" );
            chomp ($dev_name);
            $server_info{disk} = "/dev/$dev_name";
            $server_info{disk_type} = "ibm";
        } 
        if ( $dev_info =~ m{\s+(\d+)\s+(\d+)\s+(\d+)\s+(cciss/c0d0)} )  {
            my $dev_name = $4;
            next if ( $3 < "3000" );
            chomp ($dev_name);
            $server_info{disk} = "/dev/$dev_name";
            $server_info{disk_type} = "hp";
        }
        last if (exists ( $server_info{disk}) );
    }
    
    unless (exists ( $server_info{disk} ) ) { 
        print "No devices found....\n";
        print "Please let me know what device I should use.\n";
        my $loop = '0';
        while ( $loop eq '0' ) {
            my $line = <STDIN>;
            chomp $line;
            if ( $line =~ m{^\/dev\/([a-z]{3})$} ) {
                $server_info{disk} = $line;
                $loop = '1';
            }elsif ( $line =~ m{^\/dev\/c0d0} ) {
                $server_info{disk} = $line;
                $loop = '1';
            }else{
                print "Device format not understood try again!\n"
            }
        }
    }
    
    print "Found Device: $server_info{disk}\n";
    sleep 2;
    
    #Finding Network devices
    
    print "Searching for network devices...\n";
    my @ifcfg_info = `cat /proc/net/dev`;
    foreach my $ifcfg_info ( @ifcfg_info ) {
        $ifcfg_info =~ m{(eth\d)};
        my $iface = $1;
        my $eth_status = '0';
        if ( defined ($iface) ) {
            $eth_status = `/sbin/ifconfig $iface`;
            if ( $eth_status =~ m{inet\s+addr:} ) {
                 $server_info{network}->{$iface} = {
                    'status' => 'up'
                    }
            }else{
                $server_info{network}->{$iface} = {
                    'status' => 'down'
                    };
            }
        }
    }
    
    #Just incase we don't find any network cards.
    
    unless ( exists ( $server_info{network} )  ){
        print "I don't know how, but you don't have any network cards!\n";
        print "I'm going to exit now, you have bigger problems than a restore!\n";
        exit 1;
    }
    
    print "Searching for configured interfaces....\n";
    foreach my $nic (keys (% {$server_info{network} } ) ) {
        next if ( $nic eq "stuff" );
        my @if_info = `/sbin/ifconfig $nic`;
        foreach my $if_info ( @if_info ) {
            if ( $if_info =~ m{inet\saddr:} ) { 
                $if_info =~ m{inet\saddr:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})};
                $server_info{network}->{$nic}->{IPaddr} = "$1";
                $if_info =~ m{Bcast:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})};
                $server_info{network}->{$nic}->{Bcast} = "$1";
                $if_info =~ m{Mask:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})};
                $server_info{network}->{$nic}->{Mask} = "$1";
                $server_info{network}->{$nic}->{Configured} = "Yes";
            }
        }
        unless ( exists ( $server_info{network}->{$nic}->{Configured} ) ) {
            $server_info{network}->{$nic}->{Configured} = "No";
        }
    }

}

# FindTsmServers: $server_info{network},nmap --> ./$nic-tsmscan, $server_info
# Desrc: Scans all configured interfaces for TSM servers using nmap
# Ex:  &find_tsm_servers --> $server_info
#------------------------------------------------------------------------------#

sub FindTsmServers {
    my @pos_tsm_srv = ();
    foreach my $nic (keys (% {$server_info{network} } ) ) {
        if (exists ( $server_info{network}->{$nic}->{Configured} ) ) {
            if ( $server_info{network}->{$nic}->{Configured} eq "Yes" ) {
                print "Network found on $nic\n";
                print "Scanning for TSM servers....\n";
                my $netmask = $netmask_hash{$server_info{network}->{$nic}->{Mask}};
                my $ip = $server_info{network}->{$nic}->{IPaddr};
                system "nmap -p1500 -oG ./$nic-tsmscan $ip$netmask";
                @pos_tsm_srv = `cat ./$nic-tsmscan | grep -v "#" | grep open`;
            }
        }
        if ( scalar (@pos_tsm_srv ne "0" ) ) { 
            print "TSM Sources found on $nic!\n";
            print "Now lets see if it has my data!\n";
            my @old_host_file = `cat /etc/hosts`;
            foreach my $pos_tsm_srv ( @pos_tsm_srv ) {
                $pos_tsm_srv =~ m{Host:\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})};
                my $tsm_srv = $1;
                `echo "127.0.0.1    Knoppix  localhost" > /etc/hosts`;
                `echo " " >> /etc/hosts`;
                `echo "$tsm_srv     tsmsrv" >> /etc/hosts`;
                my $vnn = "-virtualnodename=$server_info{hostname}";
                my $pw = "-password=$server_info{TSM}->{Password}";
                my $tsm_out = `dsmc q sch $vnn $pw`;                  
                if ( $tsm_out =~ m{Session established with server\s+(\w+):} ) {
                    $server_info{TSM}->{Server}->{Name} = "$1";
                    $server_info{TSM}->{Server}->{IP} = "$tsm_srv";
                    print "Gotcha! I found it!!!!\n";
                }
                last if (exists ( $server_info{TSM}->{Server}) );
            }
        last if (exists ( $server_info{TSM}->{Server}) );
        }        
    last if (exists ( $server_info{TSM}->{Server}) );
    }

    unless (exists ( $server_info{TSM}->{Server}) ) {
        my $q = Term::ReadLine->new('brand');
        my $choice = $q->ask_yn(
            prompt  => "Manually enter TSM host?",
            default => 'y',
            print_me => 'Unable to locate TSM server automatically',
        );
        if ( $choice eq 'y' ) {
            &ManualTsm;
        }
    }   
}

# recap: $server_info --> STDOUT
# Desrc: Reviews information in $server_info to verify a restore can be done.
# Ex:  &recap --> STDOUT
#------------------------------------------------------------------------------#

sub recap {
    print "Hostname:$server_info{hostname}\n";
    print "Hard Disk:$server_info{disk}\n";
    if ( exists ( $server_info{TSM}->{Server} ) ) {
        my $tsm_server = $server_info{TSM}->{Server}->{Name};
        my $tsm_server_ip = $server_info{TSM}->{Server}->{IP};
        print "TSM Server: $tsm_server\n";
        print "TSM Server IP: $tsm_server_ip\n";
        my $term = Term::ReadLine->new('brand');
        my $answer = $term->ask_yn(
        prompt  => "Would you like to restore with the above settings?",
        default => 'y',
        );
        if ( $answer eq '0' ) {
            print "Exiting on your request\n";
            exit 0;
        }elsif ( $answer eq '1' ) {
            &DoWork;
        }
    }else{
        print "TSM Server: Unable to find\n";
        print "TSM Server IP: Unknown\n";
        print "Tsm Source not found\n";
        print "Exiting Script, rerun once you\'ve corrected the issue\n";
        exit 3;
    }
    
}

# PartDisk: $server_info{disk},parted --> parted,STDOUT
# Desrc: Partitions the device found.
# Ex:  &part_disk --> STDOUT,parted
#------------------------------------------------------------------------------#
    
sub PartDisk {
    print "Here we go!\n";
    print "------------------------------------------------------------------\n";
    print "The hard drive will be formatted in 10 seconds, unless you ctrl-c\n";
    sleep 10;
    print "FORMATTING $server_info{disk}\n";
    `dd if=/dev/zero of=$server_info{disk} bs=1MB count=400`;
    print "Partitioning Disk.......\n";
    my $device = "$server_info{disk}";
    `parted $device mklabel -s msdos`;
    my @disk_size = `parted $device unit mb print`;
    foreach my $disk_size ( @disk_size ) {
        if ( $disk_size =~ m{Disk\s+$device:\s+(\d+)MB} ) {
            $server_info{disk_size} = "$1";
        }
    }
    unless ( exists ( $server_info{disk_size} ) ) {
        print "Unable to find disk size, is parted working?\n";
        exit 5;
    }
    my @plab = ();
    if ( $server_info{disk_type} eq "ibm" ) {
        @plab = qw ( 1 2 3 );
    }elsif ( $server_info{disk_type} eq "hp" ) {
        @plab = qw ( p1 p2 p3 );
    }
    $server_info{disk_info}->{root} = "$device" . "$plab[0]";
    $server_info{disk_info}->{swap} = "$device" . "$plab[1]";
    $server_info{disk_info}->{lvm} = "$device" . "$plab[2]";
    
    # Gathering old root size
    my @root_fs = ();
    my $rsize = "2049";
    foreach my $cmd_ref  (@{$sysinfo_data})  {
        my $exe_cmd = $cmd_ref->{'executed_cmd'};
        my $cmd_output = $cmd_ref->{'cmd_output'};
        if ( $exe_cmd =~ m{\/bin\/df -k} ) {
            @root_fs = (@{$cmd_output});
        }
    }
        foreach my $line ( @root_fs ) {
        if ( $line =~ m{$server_info{disk}}i ) {
            $line =~ m{(/\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%\s+(/\S*)};
            my $total_size = $2;
            $rsize = int($total_size / 1024);
        }
    }
    
    my @fstab_ary = ();
    foreach my $cmd_ref  (@{$sysinfo_data})  {
        my $exe_cmd = $cmd_ref->{'executed_cmd'};
     my $cmd_output = $cmd_ref->{'cmd_output'};
     if ( $exe_cmd =~ m{\/bin\/cat\s+\/etc\/fstab} ) {
         @fstab_ary = (@{$cmd_output});
     }
    }
    
    foreach my $fsdev ( @fstab_ary ) {
        
        $fsdev =~ m{(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S*)};
        next if ( $2 eq "swap" );;
        $server_info{fstab}->{$2}->{dev} = "$1";
        $server_info{fstab}->{$2}->{fs_type} = "$3";
    }
    
    # Needed this as a global, stupid mount order!!!
    @fstab_ary2 = @fstab_ary;
    
    #Make Root
    my $rootfs = $server_info{fstab}->{'/'}->{fs_type};
    print "Making root partition....\n";
    `parted $device -s mkpart primary $rootfs 1 $rsize`;
    sleep 2;
    $rsize++;
    #Make Swap
    my $size_point = int($rsize + 2050);
    print "Making swap partition....\n";
    `parted $device -s mkpart primary linux-swap $rsize $size_point`;
    sleep 2;
    #Make LVM Partition
    $size_point++;
    print "Making LVM partition....\n";
    `parted $device -s mkpart primary reiserfs $size_point $server_info{disk_size}`;
    sleep 3;
    `parted $device -s set 3 lvm on`;
    sleep 2;
   
    #Formatting Root partition
    
    print "Formatting root partition $rootfs....\n";
    sleep 2;
    if ( $rootfs eq "ext3" ) {
        system "mkfs.ext3 -I 128 $server_info{disk_info}->{root}";
    }elsif ( $rootfs eq "ext2" ) {
        system "mkfs.ext2 -I 128 $server_info{disk_info}->{root}";
    }elsif ( $rootfs eq "reiserfs" ) {
        system "mkfs.reiserfs -q  $server_info{disk_info}->{root}";
    }else{
        system "echo \"y\" | mkfs -t $rootfs $server_info{disk_info}->{root}";
    }

    #Creating pv for lvm
    sleep 3;
    print "Creating volume group for LVM...\n";
    sleep 2;
    system "pvcreate $server_info{disk_info}->{lvm}";
    sleep 2;
    system "vgcreate -s 4M rootvg $server_info{disk_info}->{lvm}";
    print "Disk configuration complete!\n";
    sleep 5;
    
}

# restore_root: $server_info,dsmc --> $server_info{disk}
# Desrc: Restores root files to /restore_root, and the sysinfo file.
# Ex: &restore_root --> STDOUT, Local Drive!!
#------------------------------------------------------------------------------#

sub RestoreRoot {
    print "\n\n\n\n";
    print "Restoring root filesystem\n";
    print "-----------------------------------------------------\n";
    
    # Making restore point
    `mkdir /restore_root`;
    print "Waiting for mount point to come online....\n";
    my $looper = '0';
    my $count = '0';
    while ( $looper eq '0' ) {
        sleep 7;
        # Mounting restore point
         my $root = $server_info{disk_info}->{root};
        `mount $root /restore_root`;
        my $mntchk = `df -Ph | grep restore_root`;
        if ( $mntchk !~ m{restore_root} &&  $count eq "3" ) {
            print "Failed to mount root volume! Exiting.\n";
            &wlog('Failed to mount root volume, Exiting.');
            exit 244;
        }
        $count++;
        if ( $mntchk =~ m{restore_root} ) {
            $looper++;
            print "restore_root mounted succesfully!\n";
        }
    }
    #---Restoring root.
    my $max_procs = '6';
    my $pmr =  new Parallel::ForkManager($max_procs);
    $pmr->run_on_start(
        sub {
            my ($pid,$id)=@_;
            &wlog("Restore for $id started with PID:$pid");
            &FsToRestore;
            &GetRestoreFileTotal('/');
        }
    );
    $pmr->run_on_wait(
    sub {
    &MarkRestored('/restore_root/root-restore.log','/');
    my $percent = &GetRestorePercent('/');
    system "clear";
    print "Restores for the root file systems in progress!\n";
    &WriteBar($percent, 'Restore of /'),
    },
    10
    );
    my $pid = $pmr->start('root_restore');
    my $vnn = "-virtualnodename=$server_info{hostname}";
    my $pw = "-password=$server_info{TSM}->{Password}";
    my $rst_cmd = "dsmc restore -subdir=yes";
    `$rst_cmd $vnn $pw / /restore_root/ > /restore_root/root-restore.log 2>&1`;
    $pmr->finish;
    
    $pmr->wait_all_children;
    
    system "reset";
    sleep 2;
    #--Recreating directories that don't get backed up.

    `mkdir -p /restore_root/proc`;
    `mkdir -p /restore_root/dev/pts`;
    `mkdir -p /restore_root/dev/shm`;
    `mkdir -p /restore_root/sys`;
    &wlog("Creating Log file for DR");
    &wlog("Restore of root file system complete!");
}


# LvmCreate: $server_info{sysinfo-file} --> STDOUT,lvm
# Desrc: Reads the sys-info file and compares the size/availability of current
# lv's. It then creates the ones that are missing, increases the size if to
# small, and leaves everything else alone.
# Ex: &lvm_create --> STDOUT, lvm commands.
#------------------------------------------------------------------------------#

sub LvmCreate {
    print "Checking sysinfo file for LVM information!\n";
    print "-----------------------------------------------------------------\n";
    my @file_system = ();   
    #---Putting all the LVS into an array.

    foreach my $cmd_ref  (@{$sysinfo_data})  {
        my $exe_cmd = $cmd_ref->{'executed_cmd'};
        my $cmd_output = $cmd_ref->{'cmd_output'};
        if ( $exe_cmd =~ m{\/sbin\/lvs} ) {
            @file_system = (@{$cmd_output});
        }
    }
    

    my %lvs = (); # - Hash to create the LVS again
    
    # Moving data from array to hash format.

    foreach my $fs (@file_system) {
         if ( $fs =~ m{(\w+)\s+(\w+)\s+(\S+)\s+(\S+)}i ) {
            next if ( $2 eq "VG" );
            $lvs{$1}->{vg}   = "$2";
            $lvs{$1}->{size} = "$4";
        }
    }        
    
#------Creates the file systems that are missing.

    print "Creating logical volumes!\n";
    print "-----------------------------------------------------------------\n";
    foreach my $lv (keys ( %lvs ) ) {
        my $size = $lvs{$lv}->{size};
        my $vg   = $lvs{$lv}->{vg};
        my $fstype = "";
        my $efss = "";
        my $dev = "/dev/$vg/$lv";
        foreach my $fss (keys (%{$server_info{fstab}})) {
            if ( $server_info{fstab}->{$fss}->{dev} eq "$dev" ) {        
                $fstype = $server_info{fstab}->{$fss}->{fs_type};
                $efss = $fss;
            }
        }
        print "Creating Logical Volume $lv\n";
        `lvcreate --size $size --name $lv $vg`;
        sleep 3;
        print "Making Filesystem type: $fstype for LV:$lv\n";
        `echo "y" | mkfs -t $fstype /dev/$vg/$lv`;
        &wlog("Created: $lv in VG:$vg. Size:$size");
        sleep 5;
    }
    
    foreach my $fsdev ( @fstab_ary2 ) {
        $fsdev =~ m{(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S*)};
        next if ( $2 eq "swap" );
        my $rmount = $2;
        my $mount_p = "/restore_root$rmount";
        my $device = $1;
        next if ( $device eq "$server_info{disk_info}->{root}" );
        next if ( $rmount eq '/dev/pts' );
        next if ( $rmount =~ m{/proc}i );
        next if ( $rmount =~ m{/sys}i );
        next if ( $rmount =~ m{/media}i );
        next if ( $rmount =~ m{tmpfs}i );
        `mkdir -p $mount_p`;
        sleep 2;
        `mount $device $mount_p`;
        my $looper = '0';
        my $count = '0';
        while ( $looper eq '0' ) {
            print "Attempting to mount $mount_p.....\n";
            `mount $device $mount_p`;
            sleep 7;
            my $mntchk = `df -Ph | grep $mount_p`;
            if ( $mntchk !~ m{$mount_p} &&  $count eq "3" ) {
                print "Failed to mount $mount_p! Exiting.\n";
                &wlog("Failed to mount $mount_p! Exiting.");
                exit 244;
            }
            $count++;
            if ( $mntchk =~ m{$mount_p} ) {
                $looper++;
                print "$mount_p mounted succesfully!\n";
            }
        }
    }
}

# fs_to_restore: Finds mounted LVMs to restore
# Ex: &fs_to_restore --> $server_info{rfs}
#------------------------------------------------------------------------------#
sub FsToRestore {
    my @current_fs = `df -hP`;
    foreach my $current_fs (@current_fs) {
        if($current_fs =~ m{(/\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%\s+(/\S*)}){
            my $dev = $1;
            my $size = $2;
            my $used = $3;
            my $uper = $5;
            my $mount = $6;
            $server_info{rfs}->{$dev} = {
                size     => $size,
                used    => $used,
                mount => $mount,
                uper    => $uper,
            };
        }
    }
}

# finalize_disk: $server_info{disk_info} --> STDOUT
# Desrc: This script does the final steps required to a disk before reboot. It
# turns on the volume group, sets up grub, makes the swap space, and turns that
# on as well. 
# Ex: &finalize_disk --> STDOUT.
#------------------------------------------------------------------------------#

sub FinalizeDisk {

    #--- Makes the VG available.
    print "Finalizing disk........\n";
    print "Makeing the volume group available......\n";
    sleep 2;
    system "vgchange -a y rootvg";

    #--- Updates the device.map file and creates the MBR.

    print "Setting up the GRUB!......\n";
    `mount --bind /dev/ /restore_root/dev`;
    `echo "(hd0)    $server_info{disk}" > /restore_root/boot/grub/device.map`;
    system "chroot /restore_root /usr/sbin/grub --batch <<EOT 1>/dev/null"
    . " 2>/dev/null\n root (hd0,0)\n setup (hd0)\n quit\n EOT\n";  

    #--- This creates a new script in init.d to enable swap on boot.
    #--- The script will run once then delete itself.

    print "Setting up Swap space...........\n";
    print "Swap will be created on reboot!\n";
    sleep 4;
    my $swp = $server_info{disk_info}->{swap};
    my $bootlocal = "/restore_root/etc/init.d/boot.local";
    my $bootlocal_bak = "/restore_root/etc/init.d/boot.local.rbackup";
    `cp $bootlocal $bootlocal_bak`;
    `echo "/sbin/mkswap $swp" >> $bootlocal`;
    `echo "/sbin/swapon -a" >> $bootlocal`;
    `echo "mv $bootlocal_bak $bootlocal" >> $bootlocal`;
}

# find_mismatch: /boot/grub/menu.lst--> $server_info,STDOUT.
# Desrc: Checks to see if the type of disk controller matches.
# Ex: &find_mismatch --> $server_info, STDOUT.
#------------------------------------------------------------------------------#

sub FindMismatch {

    #--- Checks menu.lst to verify the root device is correct.

    print "Checking for hardware mismatch.........\n";
    sleep 3;
    my @menu = ();
    open(MNULIST,"</restore_root/boot/grub/menu.lst");
    while(<MNULIST>) {
        chomp;
        push(@menu,$_);
    }
    close MNULIST;
    foreach my $mnu (@menu) {
        if ( $mnu =~ m{root=(\S+)} ) {
            my $root = "$1";
            if ( $root ne $server_info{disk_info}->{root}  ) {
                print "Mismatch Found!!\n";
                print "Correcting error!\n";
                $server_info{hwtype}->{mismatch} = "yes"
            }else{
                $server_info{hwtype}->{mismatch} = "no"
            }
        }
    } 
}

# fix_mismatch: menu.lst,fstab,kernel,initrd--> initrd,menu.lst,fstab,kernel
# Desrc: Updates OS files with the new disk information and required modules.
# Ex: &fix_mismatch -->  initrd,menu.lst,fstab,kernel
#------------------------------------------------------------------------------#
sub FixMismatch {

    #--- Gathers info from menu.lst,sysconfig/kernel,and fstab.

    if ( $server_info{hwtype}->{mismatch} eq "yes" ) {
        my @kernel = ();
        my @fstab = ();
        my @mkrd = ();
        my @menu = ();
        my @menu2 = ();
        open(MNULIST,"</restore_root/boot/grub/menu.lst");
        while(<MNULIST>) {
            chomp;
            push(@menu,$_);
        }
        close MNULIST;
        open(KERN,"</restore_root/etc/sysconfig/kernel");
        while(<KERN>) {
            chomp;
            push(@kernel,$_);
        }
        close KERN;
        open(FSTAB,"</restore_root/etc/fstab");
        while(<FSTAB>) {
            chomp;
            push(@fstab,$_);
        }
        close FSTAB;
        
#------------------------------------------------------------------------------#
        #--- Updates the menu.list with the proper root device.
        print "Fixing Grub menu\n!";   
        sleep 1;
        open(MOUT,">/restore_root/boot/grub/menu.lst");
        foreach my $mnu (@menu) {
            if ( $mnu =~ m{root=(\S+)} ) {
                my $root = "$1";
                if ( $root ne $server_info{disk_info}->{root}  ) {
                    $root = "root=$server_info{disk_info}->{root}";
                    $mnu =~ m{(.*)(root=\S+)(.*)};
                    $mnu = "$1 $root $3";
                }
            }
        print MOUT "$mnu\n";
        }
        close MOUT;

        open(MENLST,"</restore_root/boot/grub/menu.lst");
        while(<MENLST>) {
            chomp;
            push(@menu2,$_);
        }
        close MENLST;

        open(M2OUT,">/restore_root/boot/grub/menu.lst");
        foreach my $mnu2 (@menu2) {
            if ( $mnu2 =~ m{resume=(\S+)} ) {
                my $resume = "$1";
                if ( $resume ne $server_info{disk_info}->{swap}  ) {
                    $resume = "resume=$server_info{disk_info}->{swap}";
                    $mnu2 =~ m{(.*)(resume=\S+)(.*)};
                    $mnu2 = "$1 $resume $3";
                }
            }
            print M2OUT "$mnu2\n";
        }
        close M2OUT;
#------------------------------------------------------------------------------#

        #--- Updates the root and swap devices to be mounted at boot.

        print "Fixing FSTAB!\n";
        open(FSTAB2,">/restore_root/etc/fstab");
        foreach my $fstab (@fstab) {
            $fstab =~ m{(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)};
            my $device = "$1";
            my $mp = "$3";
            if ( $mp =~ m{^\/$} && $device ne $server_info{disk_info}->{root} ) {
                $fstab =~ m{(\S+)(.*)};
                $fstab = "$server_info{disk_info}->{root} $2";
            }
            if ( $mp eq "swap" && $device ne $server_info{disk_info}->{swap} ) {
                $fstab =~ m{(\S+)(.*)};
                $fstab = "$server_info{disk_info}->{swap} $2";
            }
            print FSTAB2 "$fstab\n";
        }
        close FSTAB2;

#------------------------------------------------------------------------------#

        #--- Adds the needed modules to the kernel file, for initrd.

        print "\n";
        print "Fixing /etc/sysconfig/kernel\n";
        sleep 2;
        open(KERN2,">/restore_root/etc/sysconfig/kernel");
        foreach my $kern (@kernel) {
            if ( $kern =~ m{INITRD_MODULES=(.*)} ) {
                my $hp_init = "\"cciss reiserfs\"";
                my $ibm_init = "\"mptspi reiserfs\"";
                if ( $server_info{disk_type} eq "hp" ) {
                    $kern = "INITRD_MODULES=$hp_init";
                }
                if ( $server_info{disk_type} eq "ibm" ) {
                    $kern = "INITRD_MODULES=$ibm_init";
                }
            }
            print KERN2 "$kern\n"
        }
        close KERN2;

#------------------------------------------------------------------------------#
        
        #--- Removes and creates a new initrd file.

        print "Fixing initrd!\n";
        sleep 3;
        system "rm /restore_root/boot/initrd-*bigsmp";
        my $rootdev = "$server_info{disk_info}->{root}";
        system "chroot /restore_root /sbin/mk_initrd -d $rootdev";
        &wlog('Created new initrd!');
    }        
}

# finish_print: --> STDOUT
# Desrc: Prints out the end of the script. Nothing major.
# Ex: &finish_print --> STDOUT.
#------------------------------------------------------------------------------#

sub FinishPrint {
    print "\n\n\n\n\n\n";
    print "-----------------------------------------------------------------\n";
    print "Copying dsmerror.log to /restore_root/tmp/\n";
    system "cp /opt/tivoli/tsm/client/ba/bin/dsmerror.log /restore_root/tmp/";
    print "-----------------------------------------------------------------\n";
    print "-----------------------------------------------------------------\n";
    print "The restore has been completed!\n";
    print "You will need to do the following......\n";
    print "Review the error log in /restore_root/tmp/dsmerror.log\n";
    print "Reboot!\n";
    print ".......\n";
    print "Once you're done,verify network connectivity. That's it!\n";
}

# ManualTsm: STDIN -> $server_info{TSM}
# Desrc: This sub allows the user to manually enter a TSM source if the script
# is unable to find one.
# Ex: &ManualTsm --> $server_info{TSM}.
#------------------------------------------------------------------------------#
sub ManualTsm {
    my $mantsmq = Term::ReadLine->new('brand');
    $server_info{TSM}->{Server}->{Name} = $mantsmq->get_reply(
        prompt  => "What is the hostname of the TSM server you would like to use?",
        allow   => qr/^\w+$/,
    );
    $server_info{TSM}->{Server}->{IP} = $mantsmq->get_reply(
        prompt  => "What IP address is the TSM server located at?",
        allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
    );
    `echo "$server_info{TSM}->{Server}->{IP}   tsmsrv" >> /etc/hosts`; 
}

# RestoreLvms: Uses the ForkManager.pm to spawn multiple restore sessions.
# Desrc: This sub performs the actual restore for the LVMs. It also monitors the
# filesystem sizes. In the event a filesystem reaches 95%, it will automatically
# add 512MB of space to that file system.
# Ex: &forked_procs --> dsmc restore to LVMs
#------------------------------------------------------------------------------#
sub RestoreLvms {	
    system "clear";
    my $max_procs = '5';
    my $pm =  new Parallel::ForkManager($max_procs);

  # Setup a callback for when a child finishes up so we can
  # get it's exit code
  $pm->run_on_finish(
    sub {
        my ($pid, $ec, $id) = @_;
        $server_info{pids}->{$pid}->{status} = "Complete";
        $server_info{pids}->{$pid}->{exit_code} = "$ec";
        &wlog("Restore for $id complete. PID:$pid Exit:$ec");
    }
  );

  $pm->run_on_start(
    sub {
        my ($pid,$id)=@_;
        &wlog("Restore for $id started with PID:$pid");
        my $mp = $server_info{rfs}{$id}->{mount};
        $mp =~ m{\/restore_root(.*)};
        my $rp = $1;
        $id =~ m{\/mapper/(\w+-\w+)};
        my $loginfo = $1;
        $server_info{pids}->{$pid} = {
                    mount => "$rp",
                    loginfo => "$loginfo",
                    status  => "Running",
                };
    }
  );

  $pm->run_on_wait(
    sub {
      system "clear";
      &FsToRestore;
      foreach my $fs (keys (%{$server_info{rfs}} ) ) {
           if ( $server_info{rfs}{$fs}->{uper} gt "94" ) {
                &wlog("$fs has reached 95% full, increasing by 512mb");
                $fs =~ m{\/mapper/(\w+)-(\w+)};
                my $vg = $1;
                my $lv = $2;
                my $dev = "/dev/$vg/$lv";
                my $fstype = "";
                foreach my $fss (keys (%{$server_info{fstab}})) {
                    if ( $server_info{fstab}->{$fss}->{dev} eq "$dev" ) {        
                       $fstype = $server_info{fstab}->{$fss}->{fs_type};
                    }
                }
                `lvresize -L+512MB $dev`;
                if ( $fstype eq "reiserfs" ) {
                    `resize_reiserfs $dev`;
                }elsif ( $fstype eq "ext3" ) {
                    `resize2fs $dev`;
                }elsif ( $fstype eq "ext2" ) {
                    `resize2fs $dev`;
                }else{
                    &wlog('Unable to increase FS size, FS type unknown!')
                }
            }
       }
      print "Restores for the following file systems in progress!\n";
      foreach my $proc ( sort (keys (%{$server_info{pids}} ) ) ) {
        my $fs = $server_info{pids}->{$proc}->{mount};
        if ( $server_info{pids}{$proc}->{status} eq "Running" ) {
            my $log_file = $server_info{pids}{$proc}->{loginfo};
            &MarkRestored("/restore_root/$log_file-restore.log",$fs);
            my $percent = &GetRestorePercent($fs);
            &WriteBar( $percent, "$fs");
        }elsif ( $server_info{pids}{$proc}->{status} eq "Complete" ) {
              my $exit = $server_info{pids}{$proc}->{exit_code};
              my $out;
              my $percent = &GetRestorePercent($fs);
              if (defined $server_info{TSM}{exit_codes}->{$exit} ) {
                  $out = $server_info{TSM}{exit_codes}->{$exit};
                  $server_info{bars}->{$fs} = {
                    percent => "$percent",
                    out => "$out",
                    };
              }else{
                    $server_info{bars}->{$fs} = {
                        percent => "$percent",
                    };
              }
        }
      }
      if ( exists $server_info{bars} ) {
        print "\n";
        print "The following restores are complete!\n";
        foreach my $filesys (keys (%{$server_info{bars}}) )  {
          my $p = $server_info{bars}->{$filesys}->{percent};
          my $o = '';
          if ( defined $server_info{bars}->{$filesys}->{out} ) {
            $o = $server_info{bars}->{$filesys}->{out};
            print "$filesys:$p\%:$o\n";
          }else{
            print "$filesys:$p\%\n";
          }
        }
      }
    },
    10
  );
  
    foreach my $lv_restore (keys (%{$server_info{rfs}} ) ) {
        if ( $lv_restore =~ m{\/dev\/mapper\/.*}) {
            my $pid = $pm->start($lv_restore) and next;
            my $mp = "$server_info{rfs}{$lv_restore}->{mount}";
            my $op = '';
            $lv_restore =~ m{\/dev\/mapper\/(.*)};
            my $device = $1;
            if ( $mp =~ m{\/restore_root(.*)} ) { 
                $op = "$1/";
            }
            my $rp = "$server_info{rfs}{$lv_restore}->{mount}/";
            sleep 1;
            my $restore_cmd = "dsmc restore -subdir=yes -replace=no";
            my $vnn = "-virtualnodename=$server_info{hostname}";
            my $pw = "-password=$server_info{TSM}->{Password}";
            &wlog("$restore_cmd $vnn $pw $op $rp");
            `$restore_cmd $vnn $pw $op $rp > /restore_root/$device-restore.log 2>&1`;
            $server_info{rfs}->{$lv_restore}->{log} = "/restore_root/$device-restore.log";
            $pm->finish;
        }
    }
    $pm->wait_all_children;
    system "reset";
    sleep 2;
    print "All restores are complete!\n";
}

# wlog: shift -> dr.log
# Desrc: This sub is used to write information to the log file. It accepts one
# argument which is written to the log file with a timestamp.
# Ex: &wlog("I'm writing stuff" --> /restore_root/dr.log
#------------------------------------------------------------------------------#
sub wlog
{
    my $arg  = shift;
    my $logfile = '/restore_root/dr.log';
    if ( -e $logfile ) {
    chomp(my $timestamp = `date "+%x %R:%S"`);
    open(OUTPUT,">>$logfile");
    print OUTPUT "$timestamp: $arg\n";
	close OUTPUT;
    }else{
        `touch $logfile`;
        `chmod 777 $logfile`;
        chomp(my $timestamp = `date "+%x %R:%S"`);
        open(OUTPUT,">>$logfile");
        print OUTPUT "$timestamp: $arg\n";
        close OUTPUT;
    }
}

# Loading TSM Option files.
#---These to files aren't updated on install, so this fixes that.
# I just made this a sub to clean up the script.
sub LoadTsmOptions
{
open(DSMSYS,">/opt/tivoli/tsm/client/ba/bin/dsm.sys");
print DSMSYS <<'EOF';
************************************************************************
* Tivoli Storage Manager                                               *
*                                                                      *
* Sample Client System Options file for AIX and SunOS (dsm.sys.smp)    *
************************************************************************

*  This file contains the minimum options required to get started
*  using TSM.  Copy dsm.sys.smp to dsm.sys.  In the dsm.sys file,
*  enter the appropriate values for each option listed below and
*  remove the leading asterisk (*) for each one.

*  If your client node communicates with multiple TSM servers, be
*  sure to add a stanza, beginning with the SERVERNAME option, for
*  each additional server.

************************************************************************

SErvername  server_a
   COMMmethod         TCPip
   TCPPort            1500
   TCPServeraddress tsmsrv
changingretries 1
maxcmdretries   4
tcpbuffsize     512
txnbytelimit    2097152
resourceutilization     10
schedlogretention       14 D
passwordaccess  generate
schedlogname /opt/tivoli/tsm/client/ba/bin/dsmsched.log
errorlogname /opt/tivoli/tsm/client/ba/bin/dsmerror.log
*inclexcl /opt/tivoli/tsm/client/ba/bin/inclexcl.dat
EOF

close DSMSYS;

open(DSMOPT,">/opt/tivoli/tsm/client/ba/bin/dsm.opt");
print DSMOPT <<'EOF';
************************************************************************
* Tivoli Storage Manager                                               *
*                                                                      *
* Sample Client User Options file for AIX and SunOS (dsm.opt.smp)      *
************************************************************************

*  This file contains an option you can use to specify the TSM
*  server to contact if more than one is defined in your client
*  system options file (dsm.sys).  Copy dsm.opt.smp to dsm.opt.
*  If you enter a server name for the option below, remove the
*  leading asterisk (*).

************************************************************************

* SErvername       A server name defined in the dsm.sys

REPLace         ALL
* SCROLLINES    20
scrollprompt    yes
tapeprompt      no
timeformat      1
EOF
close DSMOPT;
};

# net_setup: STDIN -> network interface
# Desrc: Asks user for IP information to assign to either the bond or
# the standard interface. Then ifconfigures the interface.
# Ex: &net_setup --> ifconfig $interface
#------------------------------------------------------------------------------#
sub NetSetup
{
    if ( $server_info{network}->{stuff}->{bond} eq "n" ) {
        system "clear";
        my $eth = $server_info{network}{stuff}{picnic};
        print "Preparing to configure: $eth\n";
        my $ip = $server_info{network}->{stuff}->{iptoset};
        my $sn = $server_info{network}->{stuff}->{subtoset};
        `ifconfig $eth $ip netmask $sn up`;
        if ( $server_info{network}->{stuff}->{d_gw} ne "none" ) {
            print "Setting default gateway......\n";
            `ip route add default via $server_info{network}->{stuff}->{d_gw}`;
        }
        $server_info{network}->{$eth}->{Configured} = "Yes";
    }elsif ( $server_info{network}->{stuff}->{bond} eq "y" ) {
        print "Configuring eth0 as a bonded interface.....\n";
        print "FYI, this won't be a true bond, just using the same setup";
        print " as we are using in WTC/PROD on one nic instead of two\n";
        `/sbin/modprobe 8021q`;
        `vconfig set_name_type VLAN_PLUS_VID_NO_PAD`;
        my $vlan = $server_info{network}->{stuff}->{vlan};
        `vconfig add eth0 $vlan`;
        my $ip = $server_info{network}->{stuff}->{iptoset};
        my $sn = $server_info{network}->{stuff}->{subtoset};
        `ifconfig vlan$vlan $ip netmask $sn up`;
        my $fnic = "vlan$vlan";
        $server_info{network}->{$fnic}->{Configured} = "Yes";
        $server_info{network}->{$fnic}->{IPaddr} = "$ip";
        $server_info{network}->{$fnic}->{Mask}   =  "$sn";
        if ( defined ( $server_info{network}->{stuff}->{d_gw} ) ) {
            if ( $server_info{network}->{stuff}->{d_gw} ne "none" ) {
                print "Network configured, adding gateway\n";
                `ip route add default via $server_info{network}->{stuff}->{d_gw}`;
            }
        }
    }
}

#prints disclaimer at the begining of execution
sub disclaim
{
print <<'EOF';
Welcome, and thank you for using my restore script!
Please note a few things.

#1. This script assumes 2GB swap partition.
Everything else on the hard disk will be
assigned to the LVM partition.

#2. This script is not designed to support SAN volumes. You will need to recover
those by hand. (I'm guessing, I've never tested this script on a SAN
enabled Linux server.)

#3. This script depends the information collected by the sysinfo script.
If the server you are attempting to restore does not run the sysinfo script, you
will need to restore it by hand, sorry!

If any bugs are found, please let me know joel_stiller@bcbsil.com. In the event
this is being used in a real DR situation, you should be able to restore a
session to ANY x86 hardware. Please double check the image once it's back up!

Thanks, and have fun!
Joel Stiller
Press Enter to continue.....
EOF
my $hold = "0";
    while ( $hold eq "0" ) {
        my $line = <STDIN>;
        if ( $line ) {
            $hold++
        }
}
}

#---Restoring the sysinfo file.
sub RestoreSysinfo
{
    print "\n\n\n\nRestoring sysinfo to / \n\n\n";
    my $restore_cmd = "dsmc restore -subdir=yes -replace=no";
    my $vnn = "-virtualnodename=$server_info{hostname}";
    my $pw = "-password=$server_info{TSM}->{Password}";
    my $sysinfo_file = "$server_info{hostname}-sysinfo.html";
    my $sysinfo = "/var/sysinfo/$sysinfo_file";
    `mkdir /sysinfo`;
    $server_info{sysinfo_file} = "/sysinfo/$sysinfo_file";
    system "$restore_cmd $vnn $pw $sysinfo /sysinfo/$sysinfo_file";
}

#---Getting data for from sysinfo.html->@sysinfo_data
sub GetSysinfo {
#--------------------Start Rocky Code------------------------------------------#
#------Stolen from sysinfo diff! Horray!!!!------------------------------------#
# Constants
    my $HOSTNAME = "$server_info{hostname}";
    my $SYSINFO_FILE = "$server_info{sysinfo_file}";

# Storage Variables;
    my $cmd_ary_ref = [];
    my $diffs = {};
    my $return_ref = [];
    unless(-r $SYSINFO_FILE){
        die "Cannot Read $SYSINFO_FILE";
    }

# Open the html file for reading
    open(SYS,"$SYSINFO_FILE");

# Temp while loop variables
    my $tmp_hash_ref = {};

# loop stages - used for seperating out html lines
# 0 = new 
# 1 = command found, no output
# 10 = commit
    my $loop_stage = 0;

# pre stages - used for multi line pre output
# 0 = new
# 1 = start found, snag input
    my $pre_stage = 0;

#----------------------------------------------------------------------------
# File/html processing loop
#----------------------------------------------------------------------------

    while(my $file_line = <SYS>){
        chomp($file_line);

    # Command line - put in temp hash, 
        if($loop_stage == 0 and $file_line =~ m{<pre>((/\S+)[^>]*)</pre>}i){
            $tmp_hash_ref->{'executed_cmd'} = $1;
            $tmp_hash_ref->{'base_cmd'} = $2;
            $loop_stage = 1;
        }

    # Command Found - Lets get the output
        elsif($loop_stage == 1){
    # Look for output lines  
            if($pre_stage == 0){
                # Multi-line output
                if($file_line =~ m{<pre>$}i){
                    $pre_stage = 1;
                    $tmp_hash_ref->{'cmd_output'} = [];
                }   

            # Single line output
                elsif($file_line =~ m{<pre>(/[^>]+)</pre>}i){
                    $loop_stage = 10;
                    unless($file_line =~ m{^[\s]*$}i){
                        $tmp_hash_ref->{'cmd_output'}->[0] = $1;
                    }
                }
            }
        # Found a start, put the output in our temp hash ref
            elsif($pre_stage == 1 and $file_line !~ m{^</pre>$}i){
                unless($file_line =~ m{^[\s#-]*$}i){  # Don't add blank lines
                    push(@{$tmp_hash_ref->{'cmd_output'}}, $file_line);
                }
            
            }
        # Found the end of our multiline pre
            elsif($file_line =~ m{^</pre>$}i){
                $loop_stage = 10;
            }
        }
    
    # Found a complete command + output segment, reset out loop variables
    # and push what we found onto the command array
        if($loop_stage == 10){
            $loop_stage = 0;
            $pre_stage = 0;
            push(@{$cmd_ary_ref}, $tmp_hash_ref);
            $tmp_hash_ref = {};
        }

    }

    close(SYS);
    $sysinfo_data = $cmd_ary_ref;
#----------------------------End Rocky Code------------------------------------#
}

#Queries Server for Total files - Expecting value to be passed for filesystem name.
sub GetRestoreFileTotal {
    my $fs = shift;
    my $notroot = '/';
    if ( $fs ne "/" ) {
        $notroot = "$fs" . "/";
    }
    my $qcmd= 'dsmc query backup  -scrollprompt=no -subdir=yes';
    my $vnn = "-virtualnodename=$server_info{hostname}";
    my $pw = "-password=$server_info{TSM}->{Password}";
    my @data = `$qcmd $vnn $pw $notroot`;
    foreach my $data ( @data ) {
        my @fields = split /\s+/, $data;
        my $file = $fields[7];
        next if ( !defined ( $file) );
        if ( $file =~ m{(^/.*)}i ) {
            $server_info{file_list}{$fs}->{$1} = {
                'restored' => 'no',
                }
        }
    }
}

## This sub uses the File::Read module to read the output of DSMC(TSM)
## As it reads over the restored files it changes the value of
## $server_info{file_list}{mount}{file_name}->restored to yes.
## This allows the status bars to be accurate.
sub MarkRestored
{
    my $log_file = shift;
    my $mp = shift;
    my @log = read_file({ skip_comments => 1, skip_blanks => 1, aggregate => 0 },  "$log_file");
    foreach my $log ( @log ) {
        if ( $log =~ m{-->\s+/restore_root(\S+)\s+} ) {
            my $file = $1;
            $server_info{file_list}{$mp}{$file}->{restored} = "yes";
        }
    }
}

## Used to check between the total number of files and the files
## restored so far. Returns a % value as an integer.
## Expects file system as input.
sub GetRestorePercent
{
    my $fs = shift;
    my $total_files = '0';
    my $rest_files = '0';
    foreach my $file (keys (% {$server_info{file_list}->{$fs}} ) ) {
        $total_files++;
        if ( $server_info{file_list}{$fs}{$file}->{restored} eq "yes" ) {
            $rest_files++;
        }
    }
    &wlog("Restored $rest_files of $total_files files for the $fs filesystem");
    if ( $rest_files eq '0' ) {
        return $rest_files;
    }elsif ( $rest_files == $total_files ) {
        return '100';
    }else{
        my $percent = ( $rest_files / $total_files ) * 100;
        return int ($percent);
    }
        
}

## Simple sub used to ask the user a series of questions we need answered.
## This sub is using the Term::Readline module to provide a cleaner
## user interaction.
sub TextQuestions {
    my @nics = ();
    my $term = Term::ReadLine->new('brand');
    $server_info{hostname} = $term->get_reply(
        prompt  => "What is the hostname of the server you would like to restore?",
        allow   => qr/^\w+$/,
    );
    $server_info{hostname} = lc($server_info{hostname});
    my $line = $server_info{hostname};
    $line =~ tr/[a-z]/[A-Z]/;
    $server_info{TSM}->{Password} = $line;
    
    $server_info{network}->{stuff}->{bond} = $term->ask_yn(
        prompt  => "Will this be a bonded interface setup?",
        default => 'y',
    );
    if ( $server_info{network}->{stuff}->{bond} eq '0' ) {
        $server_info{network}->{stuff}->{bond} = "n";
    }elsif ( $server_info{network}->{stuff}->{bond} eq '1' ) {
        $server_info{network}->{stuff}->{bond} = "y";
    }
    if ( $server_info{network}->{stuff}->{bond} eq 'n' ) {
        foreach my $nic (keys ( %{$server_info{network}} ) ) {
            push(@nics,$nic);
        }
        $server_info{network}->{stuff}->{picnic} =  $term->get_reply(
            prompt  => "Network Card?",
            choices => [@nics],LENGTH    => '8',
            print_me => 'Which network card would you like to configure?',
        );
    }   
    $server_info{network}->{stuff}->{iptoset} = $term->get_reply(
        prompt  => "IP Address (xxx.xxx.xxx.xxx format)",
        allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
        print_me => 'What IP address would you like to set for the restore?
        This will be erased during the restore process',
    );
    $server_info{network}->{stuff}->{subtoset} = $term->get_reply(
        prompt  => "Subnet?",
        allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
        print_me => 'What is the subnet mask for this IP range?',
    );
    if ( $server_info{network}->{stuff}->{bond} eq 'y' ) {
        $server_info{network}->{stuff}->{vlan} = $term->get_reply(
            prompt  => "What vlan is this interface on?",
            allow   => qr/^\d+$/,
        );
    }
    $server_info{network}->{stuff}->{d_gw} = $term->get_reply( 
        prompt  => "Default Gateway?",
        default => 'none',
        print_me => 'Would you like to enter a default gateway? You probably don\'t need one',
    );

};

## Sub to write progress bars. Expects 2 inputs.
## Input 1 -> Value to display 1-100%
## Input 2 -> Name to display ex. /opt {##
## Input 3 -> Job Status, not required.
## Added formatting to slam everything in an 80 character line.

sub WriteBar {
    my $value = shift;
    my $id = shift;
    my $status = shift;
    my $max = 40;
    my $new_val  = $value;
    unless ( $value == 0 ) {
        $new_val = int($value / 2.5);
    }
    printf '%17.17s', "$id";
    print ": \{";
    foreach ( 0..$new_val ) {
        print "#";
    }
    my $us = ( $max - $new_val );
    foreach ( 0..$us ) {
        print "_";
    }
    if ( defined ( $status ) ) {
        printf '%.20s',"\} $value\%:$status\n";
    }else{
        printf '%.20s',"\} $value\%\n";
    }
}

## This sub calls the GetRestoreFileTotal sub to get the files to be restored
## from the TSM server. This sub was needed because the forked processes and
## the query weren't working well together, so I had to split it out.
## This sub also creates the output log files, so the Read::File module doesn't
## crash the script due to a missing filehandle.

sub getTotalFiles
{
    foreach my $fs (keys (%{$server_info{rfs}} ) ) {
    if ( $fs =~ m{\/dev\/mapper\/.*}) {
        my $mp = "$server_info{rfs}{$fs}->{mount}";
        $fs =~ m{\/dev\/mapper\/(.*)};
        my $device = $1;
        `touch /restore_root/$device-restore.log`;
        my $qp = '';
        if ( $mp =~ m{\/restore_root(.*)} ) { 
            $qp = "$1";
            print "Collecting backup information for $qp\n";
            &GetRestoreFileTotal($qp);
        }
    }
    }
}

sub NoNuke
{
    print "Control-C is captured. You will need to kill the process via another window if you really want it dead!\n";
    print "You can't hug your children with nuclear arms!\n";
}

