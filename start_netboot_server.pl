#!/usr/bin/perl -w 
use strict;
use Data::Dumper;
use Term::UI;
use Term::ReadLine;
use Term::ReadKey;

# Globals
my %server_info = ();

printf "%-5s","If you would like this script to automagically add your mac addresses to the dhcp.conf file\n";
printf "%-5s","Please create the flat file /RESTORE_FILES/macs , with one MAC address per line\n";
printf "%-5s","Press Enter to continue, or ctrl+c to add the file, then start this script again.\n";
my $hold = "0";
while ( $hold eq "0" ) {
    my $line = <STDIN>;
    if ( $line ) {
        $hold++
    }
}

print "Starting Network Boot server configuration.....\n";
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

&TextQuestions;
&NetSetup;

print "Creating dhcpd.conf!\n";
open(OUT,">/etc/dhcp3/dhcpd.conf");
print OUT "ddns-update-style none;\n";
print OUT "default-lease-time 240;\n";
print OUT "max-lease-time 240;\n\n";
print OUT "next-server $server_info{network}->{stuff}->{iptoset};\n";
print OUT "option tftp-server-name \"$server_info{network}->{stuff}->{iptoset}\";\n";
print OUT "\n";
my $subby = $server_info{network}->{dhcp}->{sub};
my $nmask = $server_info{network}->{stuff}->{subtoset};
chomp $subby;
chomp $nmask;
print OUT "subnet $subby netmask $nmask {\n";
print OUT "\tfilename \"pxelinux.0\";\n";
print OUT "\toption routers $server_info{network}->{stuff}->{d_gw};\n";
my $start_range = $server_info{network}{dhcp}->{start_range};
my $stop_range = $server_info{network}{dhcp}->{end_range};
chomp $start_range;
chomp $stop_range;
print OUT '    pool {';
print OUT "\trange $start_range $stop_range;\n";
print OUT "\tallow known clients;\n";
print OUT "\tdeny unknown clients;\n";
print OUT "    }\n";
print OUT "#  host dr1  \{ hardware ethernet XX:XX:XX:XX:XX:XX;\}\n";
my $count = "1";
if ( -r "/RESTORE_FILES/macs" ) {
    open(IN,"</RESTORE_FILES/macs");
    while ( <IN> ) {
        if ( $_ =~ m{(\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2})} ) {
            my $mac = $1;
            my $ucmac = uc($mac);
            print OUT "host dr$count \{hardware ethernet $ucmac;\}\n";
            $count++;
        }
    }
}
print OUT "\n\n\}\n";
close OUT;

print "Configuring TFTP server\n";
`mkdir -p /tftpboot/pxelinux.cfg`;
`cp /usr/lib/syslinux/pxelinux.0 /tftpboot/`;
`chown -R root.root /tftpboot`;
`chmod -R 777 /tftpboot`;
#
my @inet_ary = ();
open(INET,"</etc/inetd.conf");
while ( <INET> ) {
    my $line3 = $_;
    if ( $line3 =~ m{tftp}i ) {
        $line3 = "tftp dgram udp wait nobody /usr/sbin/in.tftpd /usr/sbin/in.tftpd -s /tftpboot\n";
    }
    push(@inet_ary,$line3);
}
close INET;
#
open(INETOUT,">/etc/inetd.conf");
foreach my $inet_ary ( @inet_ary ) {
    print INETOUT "$inet_ary\n";
}
close INETOUT;
#
my @default_ary = ();
open(DIN,"</etc/default/tftpd-hpa");
while (<DIN>) {
    my $line4 = $_;
    if ( $line4 =~ m{RUN_DAEMON}i ) {
        $line4 = 'RUN_DAEMON="yes"';
    }elsif ( $line4 =~ m{OPTIONS}i ) {
        $line4 = 'OPTIONS="-l -s /tftpboot"';
    }
    push(@default_ary,$line4);
}
close DIN;
open(DOUT,">/etc/default/tftpd-hpa");
foreach my $default_ary ( @default_ary ) {
    print DOUT "$default_ary\n";
}
close DOUT;
#
my @dhcp_ary = ();
open(DHCPIN,"</etc/default/dhcp3-server");
while ( <DHCPIN> ) {
    my $line5 = $_;
    if ( $line5 =~ m{INTERFACES} ) {
        $line5 = "INTERFACES=\"$server_info{network}{stuff}->{dhcp}\"";
    }
    push(@dhcp_ary,$line5);
}
close DHCPIN;

open(DHCPOUT,">/etc/default/dhcp3-server");
foreach my $dhcp_ary ( @dhcp_ary ) {
    print DHCPOUT "$dhcp_ary\n";
}
close DHCPOUT;
#

`cp /RESTORE_FILES/finnix /tftpboot/`;
`cp /RESTORE_FILES/FinnixBoot.pxe /tftpboot/`;
`cp /RESTORE_FILES/dr-boot /tftpboot/pxelinux.cfg/`;
`ln -s dr-boot /tftpboot/pxelinux.cfg/default`;

if ( -r "/RESTORE_FILES/macs" ) {
    open(IN,"</RESTORE_FILES/macs");
    while ( <IN> ) {
        if ( $_ =~ m{(\w{2}):(\w{2}):(\w{2}):(\w{2}):(\w{2}):(\w{2})} ) {
            my $nmac = "$1-$2-$3-$4-$5-$6";
            my $mac = lc $nmac;
            `ln -s dr-boot /tftpboot/pxelinux.cfg/01-$mac`;
        }
    }
}

`/etc/init.d/dhcp3-server restart`;
`/etc/init.d/tftpd-hpa restart`;


sub TextQuestions {
    my @nics = ();
    my $term = Term::ReadLine->new('brand');
    
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
            next if ( $nic eq "stuff" );
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
        print_me => 'What IP address would you like to set for this host?
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
        allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
        print_me => 'Default Gateway is required when setting up a DHCP Server!!',
    );
    $server_info{network}->{dhcp}->{sub} = $term->get_reply( 
        prompt  => "Subnet to Service",
        allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
        print_me => 'What subnet would you like to service for DHCP? ex. 192.168.1.0',
    );
    $server_info{network}->{dhcp}->{start_range}= $term->get_reply( 
            prompt  => "Start of DHCP Range",
            allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
            print_me => 'What is the start of the IP range to service with DHCP?',
        );
    $server_info{network}->{dhcp}->{end_range} = $term->get_reply( 
            prompt  => "End of DHCP Range",
            allow   => qr/^((\d{1,3}\.){3}\d{1,3})$/,
            print_me => 'What is the LAST IP address to be used?',
        );
};

sub NetSetup
{
    if ( $server_info{network}->{stuff}->{bond} eq "n" ) {
        system "clear";
        my $eth = $server_info{network}{stuff}{picnic};
        print "Preparing to configure: $eth\n";
        my $ip = $server_info{network}->{stuff}->{iptoset};
        my $sn = $server_info{network}->{stuff}->{subtoset};
        $server_info{network}{stuff}->{dhcp} =  "$eth";
        `ifconfig $eth $ip netmask $sn up`;
        if ( $server_info{network}->{stuff}->{d_gw} ne "none" ) {
            print "Setting default gateway......\n";
            `ip route add default via $server_info{network}->{stuff}->{d_gw}`;
        }
        $server_info{network}{stuff}->{dhcp} = "$eth";
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
        $server_info{network}{stuff}->{dhcp} = "eth0";
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

