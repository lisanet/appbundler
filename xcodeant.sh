#!/bin/sh

#  xcodeant.sh
#  appbundler-xcode
#
#  wrapper script to locate the ant binary, which might be installed in some custom location
#
#  Created by Simone Karin Lehmann on 03.01.15.
#
ANT=$(which ant)
"$ANT" $*
