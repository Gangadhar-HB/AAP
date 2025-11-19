#!/bin/python
#
# Copyright Motorola Solutions, Inc. and/or Kodiak Networks, Inc.                                 
# All Rights Reserved                                                                             
# Motorola Solutions Confidential Restricted                                                      
#

#!/usr/bin/python
#
"""
Generate dynamic inventory list for Ansible

History:

  2017-04-13 - gmorton
               initial version
               
  2017-05-16 - gmorton,
               made backwards compatible with python 2.6
                              
"""

#
# Set script version (i.e. 1.0.0)
#
gMajor='9'
gMinor='0'
gPoint='0.0'

gVersion="{0}.{1}.{2}".format(gMajor,gMinor,gPoint)


#
# Set description for usage
#
gDesc="""\
  Generate dynamic inventory list for Ansible
  Version {0}
""".format(gVersion)

 
import sys
import traceback
import os
import signal
import re
import optparse
import ConfigParser
import subprocess
import json



gCmdLineArgs = None
gCmdLineOpts = None

def parse_cmd_line():
    """
    Parse command line
    """
    
    global gVersion
    global gDesc
    global gCmdLineArgs
    global gCmdLineOpts
    
    parser = optparse.OptionParser(usage='%prog [options]',
                                   description=gDesc,
                                   version='%prog {0}'.format(gVersion))
    
     
   
    #  
    # Add command line options 
    #    
    parser.add_option("-d", "--debug", help="increase level of debug messages",
                        type=int, default=0)
                                                
    parser.add_option("-v", "--verbose", help="increase output verbosity (e.g. -v, -vv, -vvv)",
                      action="count", default=0)
    
    parser.add_option('--list', action = 'store_true')
    
                        
    # 
    # Add command line parameters
    #
    
    
    # Get command line arguments
    gCmdLineOpts, gCmdLineArgs = parser.parse_args()

           
        

     
class Inventory:
    """
    Ansible Dynamic Inventory
    """
    
    def __init__(self,
                 debuglvl = 0,
                 verboselvl = 0):
        
        self.dbglvl = debuglvl
        self.verbose = verboselvl

               
        
    def __repr__(self):
        str = "Dynamic Inventory for Ansible"   
        return str
        
        
    def generate(self, type, hosts, vms, output):
        """
        Generate inventory
        """
        try:
            if self.verbose > 0:
                print "\n  Generating inventory list for type '{0}'\n".format(type)
            
            if type.lower() == 'host_vm' :
                data = { 'bare_metal_hosts': hosts.split() , 'vm_hosts': vms.split() }
            elif type.lower() == 'vm':
                data = { 'vms': hosts.split() }          
            elif type.lower() == 'container':
                data = { 'containers': hosts.split() }     
            else:
                raise ValueError("invalid type '{0}'".format(type))
                
            if output > 0 or self.verbose > 0:
                # Pretty print json output
                print json.dumps(data, sort_keys=True, indent=4, separators=(',', ': '))
            
        except Exception as e:
            if self.verbose > 0:
                print "\n  Exception\n"
            raise



          

def signal_quit(signum, frame):
    """
    Signal handler
    """
    print "\n\n  Received signal %i, shutting down.\n\n" % signum
    
    sys.exit(signum)
        

def main():
    """
    Main Program
    """
    retval = 0

    # Configure signal handlers
    signal.signal(signal.SIGINT, signal_quit)
    signal.signal(signal.SIGTERM, signal_quit)
    

    try:

        # Parse command line
        parse_cmd_line()
        
        # Get debug level (0-5)
        debuglvl = gCmdLineOpts.debug
        
        # Get verbose level (e.g. -vvv)
        verboselvl = gCmdLineOpts.verbose
  
        # Create inventory object
        inventory = Inventory( debuglvl = debuglvl, \
                               verboselvl = verboselvl)
                                
        # Generate inventory list
        inventory.generate(type = os.environ["OS_PATCH_HOST_TYPE"], \
                           hosts = os.environ["OS_PATCH_HOST_LIST"], \
                           vms = os.environ["OS_PATCH_VM_LIST"], \
                           output = gCmdLineOpts.list)
            
    except Exception as e:
        print "\n  [ERROR> - {0}\n".format(e)
        exc_type, exc_value, exc_traceback = sys.exc_info()
        traceback.print_exception(exc_type, exc_value, exc_traceback, file=sys.stdout)
        sys.exit(1)

    sys.exit(retval)

    
#
# Code only executes if module is executed. Code is not
# executed if module is imported.
#
if __name__ == "__main__":

    main()
