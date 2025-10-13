#!/usr/bin/perl

use strict;
use warnings;

my $yaml_file = '/usr/local/bin/vmautomation-playbook/input.yml';    #need to add relative path
my $hosts_file = '/usr/local/bin/vmautomation-playbook/hosts';
my @host_ip ;

open my $fh, '<', $yaml_file or die $!;
my $content = '';
while (my $line = <$fh>) {
    $content .= $line;
}
close $fh;

my @content = split /\n/,$content;

foreach my $row (@content){
    if ($row =~ /hostip: (.*)/g) {
          if ($1 ne ''){
            push  @host_ip , $1;
          }
          else {
            print("\n++++ERROR : Hostip in input file is empty++++\n");
            exit 1;
          }
     }


}

my %seen = ();
my @uniq = ();
foreach my $item (@host_ip) {
    unless ($seen{$item}) {
        $seen{$item} = 1;
        push(@uniq, $item);
    }
}

print("++++++++++++@uniq++++++++");
system("echo [bm] > $hosts_file");

foreach my $host_ip (@uniq) {
    system("echo $host_ip >> $hosts_file");
    }

system("echo [all:vars] >> $hosts_file");
system("echo ansible_user=autoinstall >> $hosts_file");
system("echo ansible_password=kodiak >> $hosts_file");

my $time1 = `date`;

print("\n==========Starting playbook to launch VM in BM = @uniq at $time1=============\n");

my $playbook=system("ANSIBLE_CONFIG=/usr/local/bin/vmautomation-playbook/ansible.cfg ansible-playbook -i /usr/local/bin/vmautomation-playbook/hosts /usr/local/bin/vmautomation-playbook/vm_main.yml  -v");

if ($playbook !=0 ){
 print("\nERROR in playbook execution, VM lauch failed\n");
 exit(1);
}

system("rm -rf $hosts_file");

my $time2 = `date`;
print("\n================$time2========================\n");
