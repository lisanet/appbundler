#!/bin/bash -l

#  xcodeant.sh
#  appbundler-xcode
#
#  wrapper script to locate the ant binary, which might be installed in some custom location
#  This is done by simply using a login shell which uses your usual PATH
#  Created by Simone Karin Lehmann on 16.01.15.
#
ant $*

