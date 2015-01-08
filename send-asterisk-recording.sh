#!/bin/bash
##
## send-asterisk-recording.sh
##
## Upload asterisk recordings to SMB share.
##
## Copyright 2015 Borut Mrak <borut.mrak@radiostudent.si>
##
## Installation:
## 1. Copy this script somewhere on your system and make it executable.
## 2. Set parameters below under EDITABLE PARAMETERS
## 3. test upload from command line: $0 DIRECTORY FILENAME <quiet>
## 2. Install incron
## 3. Add this to /etc/incron.d/send-asterisk-recording
##    /var/spool/asterisk/monitor IN_CLOSE_WRITE /path/to/send-asterisk-recording.sh $@ $# quiet
## 4. Record a call and see it being uploaded to the destination on hangup.

##
## EDITABLE PARAMETERS
##

# Where to send reports about unsuccessful uploads.
ERROR_RECIPIENT=example@example.com

# regex for our internal CID numbers
RS_CID_REGEX='^(((386)|0)12428)?8[0-9][0-9]$'

# SMB share access parameters
SMBSHARE="//SERVERNAME_OR_IP/tmp"
SMBFOLDER="TELEFONSKI_POSNETKI"
AUTHFILE=/etc/asterisk/smbclient_auth
# see man smbclient for AUTHFILE format

# some descriptive text for destination filename
TXT_CALL="klic"
TXT_FROM="iz"
TXT_TO="na"

##
## END EDITABLE PARAMETERS. 
## CHANGING ANYTHING BELOW THIS LINE VOIDS YOUR WARRANTY!
##

# Create pretty-named variables from command-line parameters
REC_DIR=$1
REC_FILENAME=$2

function _usage() {
  echo "`basename $0` ERROR: wrong parameters"
  echo ""
  echo "Usage:"
  echo "`basename $0` [REC_DIR] [REC_FILENAME] <quiet>"
  echo ""
  echo "  REC_DIR: directory containing recordings (probably /var/spool/asterisk/monitor)"
  echo "  REC_FILENAME: the file to upload"
  echo "  quiet: do not write to stdout/stderr"
  echo ""
}




##
## Check command parameters
##
if [[ $# -lt 2 ]]; then
  logger "ERROR: `basename $0`: wrong number of parameters"
  _usage
  exit 1
fi
##
## Filename does not exist.
##
if [ ! -f $1/$2 ]; then
  logger "ERROR: `basename $0`: $1/$2 does not exist!"
  if [[ $3 != "quiet" ]]; then
    echo "ERROR: $1/$2 does not exist!"
  fi
  exit 2
fi

##
## Incron notices short-lived a- and b- leg files that are merged together
## fairly fast and deleted from under our feet (race condition).
## We don't need them, so we refuse to process them.
## 
BadFregex='-(in|out).wav$'
if [[ $2 =~ $BadFregex ]]; then
  logger "`basename $0`: $2 is not a merged recording. Not sending."
  if [[ $3 != "quiet" ]]; then
    echo "ERROR: $2 is not a merged recording. Not sending."
  fi
  exit 3
fi




TIMESTAMP=`echo $REC_FILENAME | awk -F- '{print $2}'`
REC_CID=`echo $REC_FILENAME | awk -F- '{print $3}'`
RECORDEE_CID=`echo $REC_FILENAME | awk -F- '{print $4}' | awk -F. '{print $1}'`
REC_FILETYPE=`echo $REC_FILENAME | awk -F- '{print $4}' | awk -F. '{print $2}'`

# get recording time from file timestamp in filename
REC_START=`date -d @${TIMESTAMP} +%Y-%m-%d_%H%M 2>/dev/null`
if [ $? -ne 0 ]; then
  # we failed at conversion, don't set anything.
  REC_START="xxxx-xx-xx_xxxx"
fi

# match CIDs of the recording
if [[ $REC_CID =~ $RS_CID_REGEX ]]; then
  # if recording done from inside radio CID, put file in subfolder of this extension
  DEST_SUBFOLDER=`echo $REC_CID | cut -c $((${#REC_CID}-2))-${#REC_CID}`
elif [[ $RECORDEE_CID =~ $RS_CID_REGEX ]]; then
  # if recording run from incoming call from outside radio CID, put file in callee extension subfolder
  DEST_SUBFOLDER=`echo $RECORDEE_CID | cut -c $((${#RECORDEE_CID}-2))-${#RECORDEE_CID}`
  # and also mark from where it came...
  RECORDING_FROM="-${TXT_FROM}-${REC_CID}"
  # FIXME: when we get a call from outside and the callee initiates the recording), the recording filename description is wrong.
  # REC_CID is actually the one that starts the recording, not the one that placed the call. More an annoyance than a bug,
  #         Asterisk CDR will still show the right thing if checked, only the destination name is named wrong
  # call out -> in, recorded from outside says call_to-IN-from-OUT (OK)
  # call out -> in, recorded from inside says call_to-OUT (WRONG)
  # call in -> out, recorded from inside says call_to-OUT (OK)
  # call in -> out, recorded from outside says call-to-OUT-from-IN (OK)
fi
# if still no match, DEST_SUBFOLDER is empty and we upload directly to SMBFOLDER

if [ ! -z "$DEST_SUBFOLDER" ]; then
  SMB_DESTINATION="${DEST_SUBFOLDER}/${TIMESTAMP}-${REC_START}-${TXT_CALL}_${TXT_TO}-${RECORDEE_CID}${RECORDING_FROM}.${REC_FILETYPE}"
else
  SMB_DESTINATION="${TIMESTAMP}-${REC_START}-${TXT_CALL}_${TXT_FROM}-${REC_CID}-${TXT_TO}-${RECORDEE_CID}.${REC_FILETYPE}"
fi

UPLOADCMD="smbclient -A ${AUTHFILE} ${SMBSHARE}"

## DEBUG
if [[ $3 != "quiet" ]]; then
  echo "file: ${REC_FILENAME}"
  echo -e "\tTIMESTAMP: ${TIMESTAMP}"
  echo -e "\tREC_START: ${REC_START}"
  echo -e "\tREC_CID: ${REC_CID}"
  echo -e "\tRECORDEE_CID: ${RECORDEE_CID}"
  echo -e "\tDESC_SUBFOLDER: ${DEST_SUBFOLDER}"
  echo -e "\tREC_FILETYPE: ${REC_FILETYPE}"
  echo -e ""
fi

UPLOADOUT=`${UPLOADCMD} -c "cd ${SMBFOLDER}; put ${REC_DIR}/${REC_FILENAME} ${SMB_DESTINATION}" 2>&1`
UPLOAD_RV=$?

if [[ $3 != "quiet" ]]; then
  echo "  upload command return value: $UPLOAD_RV"
  echo "  $UPLOADOUT"
  echo ""
fi

##
## notification mail if we can't upload to smb share
##
if [[ $UPLOAD_RV -ne 0 ]]; then
  mutt -s "SNEMALNIK: datoteke ${REC_FILENAME} ni bilo mogoce shraniti na ${SMBSHARE} PREVERI!" -- $ERROR_RECIPIENT </dev/null
fi
