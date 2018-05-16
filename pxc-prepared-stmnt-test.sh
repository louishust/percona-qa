#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is made for PXC Prepared SQL Statement test

if [ -z $1 ]; then
  echo "No valid parameters were passed. Need relative workdir setting. Retry.";
  echo "Usage example:"
  echo "$./pxc-prepared-stmnt-test.sh /sda/pxc-prepared-stmnt-test"
  exit 1
else
  WORKDIR=$1
fi

ROOT_FS=$WORKDIR
sst_method="xtrabackup-v2"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
echo "${SCRIPT_PWD}.."

cd $WORKDIR
count=$(ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | tail -n +2`;do
     rm -rf $dirs
  done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+

echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | head -n1`
BASEDIR="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

EXTSTATUS=0

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

if [ ! -d ${ROOT_FS}/$BASEDIR ]; then
  echo "Base directory does not exist. Fatal error.";
  exit 1
else
  BASEDIR="${ROOT_FS}/$BASEDIR"
fi

export PATH="$PATH:$BASEDIR/bin"

#mysql install db check

if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

archives() {
    tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
    rm -rf $WORKDIR
}

trap archives EXIT KILL

ps -ef | grep 'node[1-9].sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

check_server_startup(){
  node=$1
  echo "Waiting for ${node} to start ....."
  while true ; do
    sleep 3
	if ${BASEDIR}/bin/mysqladmin -uroot --socket=/tmp/$node.sock ping > /dev/null 2>&1; then
      break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/${node}.err
      exit 1
    fi
  done
}

pxc_startup(){
  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE1="$(( RPORT*1000 ))"
  RADDR1="$ADDR:$(( RBASE1 + 7 ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"

  RBASE2="$(( RBASE1 + 100 ))"
  RADDR2="$ADDR:$(( RBASE2 + 7 ))"
  LADDR2="$ADDR:$(( RBASE2 + 8 ))"

  RBASE3="$(( RBASE1 + 200 ))"
  RADDR3="$ADDR:$(( RBASE3 + 7 ))"
  LADDR3="$ADDR:$(( RBASE3 + 8 ))"

  SUSER=root
  SPASS=

  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"
  rm -Rf $node1 $node2 $node3
  mkdir -p $node1 $node2 $node3
  MPID_ARRAY=()

  echo "Starting PXC node1"
  ${MID} --datadir=$node1  > ${WORKDIR}/logs/node1.err 2>&1

  STARTUP_OPTIONS="--max-connections=2048 --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so --wsrep_node_incoming_address=$ADDR --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --wsrep_slave_threads=3 --log-output=none"

  CMD="${BASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${BASEDIR} --datadir=$node1 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 --log-error=${WORKDIR}/logs/node1.err --socket=/tmp/node1.sock --port=$RBASE1 --server-id=1"

  echo $CMD > ${WORKDIR}/node1_startup 2>&1
  $CMD --wsrep-new-cluster > ${WORKDIR}/logs/node1.err 2>&1 &

  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node1

  echo "Starting PXC node2"
  ${MID} --datadir=$node2  > ${WORKDIR}/logs/node2.err 2>&1 || exit 1;

  CMD="${BASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${BASEDIR} --datadir=$node2 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 --log-error=${WORKDIR}/logs/node2.err --socket=/tmp/node2.sock --log-output=none --port=$RBASE2 --server-id=2"

  echo $CMD > ${WORKDIR}/node2_startup 2>&1
  $CMD > ${WORKDIR}/logs/node2.err 2>&1 &
  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node2

  echo "Starting PXC node3"
  ${MID} --datadir=$node3  > ${WORKDIR}/logs/node3.err 2>&1 || exit 1;

  CMD="${BASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${BASEDIR} --datadir=$node3 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 --log-error=${WORKDIR}/logs/node3.err --socket=/tmp/node3.sock --log-output=none --port=$RBASE3 --server-id=3"

  echo $CMD > ${WORKDIR}/node3_startup 2>&1
  $CMD  > ${WORKDIR}/logs/node3.err 2>&1 &
  # ensure that node-3 has started and has joined the group post SST
  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node3

  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/node1.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node1...'
    $BASEDIR/bin/mysql -uroot --socket=/tmp/node1.sock -e"CREATE DATABASE IF NOT EXISTS test" > /dev/null 2>&1
  else
    echo 'PXC node1 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/node2.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node2...'
  else
    echo 'PXC node2 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/node3.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node3...'
  else
    echo 'PXC node3 not stated...'
  fi
}

pxc_startup
check_script(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID}. Terminating!"; exit 1; fi
}

#Initiate PXC prepared statement
$BASEDIR/bin/mysql  -uroot -S/tmp/node1.sock -e"source $SCRIPT_PWD/prepared_statements.sql" 2>/dev/null 2>&1 &
sleep 60
echo "Starting single node recovery test"
kill -9 ${MPID_ARRAY[2]}
sleep 10
STARTUP_NODE3=$(cat $WORKDIR/node3_startup)
$STARTUP_NODE3  > ${WORKDIR}/logs/node3.err 2>&1 &
MPID="$!"
MPID_ARRAY[2]=$MPID
check_server_startup node3
echo "PXC prepared statement recovery test completed"

echo "Adding new node to cluster"
node4="${WORKDIR}/node4"
rm -Rf $node4
mkdir -p $node4
RBASE4="$(( RBASE1 + 300 ))"
RADDR4="$ADDR:$(( RBASE4 + 7 ))"
LADDR4="$ADDR:$(( RBASE4 + 8 ))"
${MID} --datadir=$node4  > ${WORKDIR}/logs/node4.err 2>&1

CMD="${BASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${BASEDIR} --datadir=$node4 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3,gcomm://$LADDR4 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR4 --log-error=${WORKDIR}/logs/node4.err --socket=/tmp/node4.sock --log-output=none --port=$RBASE4 --server-id=4"

$CMD  > ${WORKDIR}/logs/node4.err 2>&1 &

check_server_startup node4
if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/node4.sock ping > /dev/null 2>&1; then
  echo 'Started PXC node4...'
else
  echo 'PXC node4 not stated...'
fi

sleep 100

${BASEDIR}/bin/mysqladmin  --socket=/tmp/node4.sock  -u root shutdown
${BASEDIR}/bin/mysqladmin  --socket=/tmp/node3.sock  -u root shutdown
${BASEDIR}/bin/mysqladmin  --socket=/tmp/node2.sock  -u root shutdown
${BASEDIR}/bin/mysqladmin  --socket=/tmp/node1.sock  -u root shutdown

exit $EXTSTATUS

