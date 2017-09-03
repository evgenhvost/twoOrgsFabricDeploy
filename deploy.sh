#!/bin/bash -e

ssh-add ~/.ssh/fabric.rsa

getIP() {
        ssh $1 "ip addr | grep 'inet .*global' | cut -f 6 -d ' ' | cut -f1 -d '/' | head -n 1"
}

probePeerOrOrderer() {
	echo "" | nc $1 7050 && return 0
	echo "" | nc $1 7051 && return 0
	return 1
}

probeFabric() {
        ssh evgenyh@$1 "ls /opt/gopath/src/github.com/hyperledger/fabric/ &> /dev/null || echo 'not found'" | grep -q "not found"
        if [ $? -eq 0 ];then
                echo "1"
                return
        fi
        echo "0"
}

deployFabric() {
        echo "Copying 'install.sh' to $1 and running it"
        scp install.sh evgenyh@$1:install.sh
        ssh evgenyh@$1 "bash install.sh"
}

invoke() {
        CORE_PEER_LOCALMSPID=PeerOrg CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/hrl.ibm.il/users/Admin@hrl.ibm.il/msp/ CORE_PEER_ADDRESS=$1:7051 ./peer chaincode invoke -c '{"Args":["invoke","a","b","10"]}' -C yacov -n exampleCC -v 1.0  --tls true --cafile `pwd`/crypto-config/ordererOrganizations/hrl.ibm.il/orderers/${orderer}.hrl.ibm.il/tls/ca.crt
}

[[ -z $GOPATH ]] && (echo "Environment variable GOPATH isn't set!"; exit 1)
FABRIC=$GOPATH/src/github.com/hyperledger/fabric
[[ -d "$FABRIC" ]] || (echo "Directory $FABRIC doesn't exist!"; exit 1)
for file in configtxgen peer cryptogen; do
	[[ -f $file ]] && continue
	binary=$FABRIC/build/bin/$file
	[[ ! -f $binary ]] && ( cd $FABRIC ; make $file)
	cp $binary $file && continue
done

for file in configtxgen peer cryptogen; do
	[[ ! -f $file ]] && echo "$file isn't found, aborting!" && exit 1
done

org1_peers=( peer0.org1 peer1.org1 )
org2_peers=( peer0.org2 )
orderer=( orderer )

all_peers=( "${org1_peers[@]}" "${org2_peers[@]}" )

declare -A ips=(    ["orderer"]="9.148.244.225" \
                    ["peer0.org1"]="9.148.245.3" \
                    ["peer1.org1"]="9.148.245.10" \
                    ["peer0.org2"]="9.148.244.243" \
                    ["peer1.org2"]="9.148.244.225" )

orderer_ip=${ips[orderer]}

for p in ${orderer[*]} ${all_peers[*]} ; do
        echo "Checking if fabric is installed on ${ips[$p]}"
        if [ `probeFabric ${ips[$p]}` == "1" ] ; then
                echo "Didn't detect fabric installation on $p, proceeding to install fabric on it"
                deployFabric ${ips[$p]}
        else
            echo "Fabric is installed"
        fi
done

echo "Preparing configuration..."
rm -rf crypto-config  # Remove previous crypto-gen generated files
for p in ${orderer[*]} ${all_peers[*]} ; do
	rm -rf ${p}  # Will delete the previous dirs created for each one
done

for p in ${orderer[*]} ${all_peers[*]} ; do
        mkdir -p ${p}/sampleconfig/crypto
        mkdir -p ${p}/sampleconfig/tls
done

PROPAGATEPEERNUM=${PROPAGATEPEERNUM:-3}

i=0
org1BootPeer=${ips[${org1_peers[0]}]}
for p in ${orderer[*]} ${org1_peers[*]} ; do
        ip=${ips[$p]}
        orgLeader=false
        orgMsp=OrdererOrg
        if [[ ${i} -eq 1 ]] ; then
            orgLeader=true
        fi
        if [[ ${i} -gt 0 ]] ; then
            orgMsp=Org1MSP
        fi
        (( i += 1 ))
        echo "Updating core yaml of $p of Org1 on ip=$ip orgLead=$orgLeader peerID=$ip bootPeer=$org1BootPeer"
        cat core.yaml.template | sed "s/PROPAGATEPEERNUM/${PROPAGATEPEERNUM}/ ; s/ORG_MSP/$orgMsp/ ; s/PEERID/$ip/ ; s/ADDRESS/$ip/ ; s/ORGLEADER/$orgLeader/ ; s/BOOTSTRAP/$org1BootPeer:7051/   ; s/TLS_CERT/$ip.example.com-cert.pem/"    > ${p}/sampleconfig/core.yaml
done

i=0
org2BootPeer=${ips[${org2_peers[0]}]}
for p in ${org2_peers[*]} ; do
        ip=${ips[$p]}
        orgLeader=false
        if [[ ${i} -eq 0 ]] ; then
            orgLeader=true
        fi
        (( i += 1 ))
        echo "Updating core yaml of $p of Org2 on ip=$ip orgLead=$orgLeader peerID=$ip bootPeer=$org2BootPeer"
        cat core.yaml.template | sed "s/PROPAGATEPEERNUM/${PROPAGATEPEERNUM}/ ; s/ORG_MSP/Org2MSP/ ; s/PEERID/$ip/ ; s/ADDRESS/$ip/ ; s/ORGLEADER/$orgLeader/ ; s/BOOTSTRAP/$org2BootPeer:7051/   ; s/TLS_CERT/$ip.example.com-cert.pem/"    > ${p}/sampleconfig/core.yaml
done

echo "Generating crypto content"
./cryptogen generate --config crypto-config.yml

echo "Generating genesis block from config"
./configtxgen -profile TwoOrgsOrdererGenesis -outputBlock genesis.block -channelID system

echo "Generating channel configs"
./configtxgen -profile TwoOrgsChannel -outputCreateChannelTx example-cc.tx -channelID example-cc



mv genesis.block orderer/sampleconfig/
cp orderer.yaml orderer/sampleconfig/

echo "Copying orderer msp crypto content"
cp -r crypto-config/ordererOrganizations/example.com/orderers/${ips[orderer]}.example.com/msp/* orderer/sampleconfig/crypto
cp -r crypto-config/ordererOrganizations/example.com/orderers/${ips[orderer]}.example.com/tls/* orderer/sampleconfig/tls

for p in ${org1_peers[*]} ; do
        ip=${ips[$p]}
        echo "Copying crypto content for $p in Org1"
        cp -r crypto-config/peerOrganizations/org1.example.com/peers/${ip}.org1.example.com/msp/* ${p}/sampleconfig/crypto
        cp -r crypto-config/peerOrganizations/org1.example.com/peers/${ip}.org1.example.com/tls/* ${p}/sampleconfig/tls/
done

for p in ${org2_peers[*]} ; do
        ip=${ips[$p]}
        echo "Copying crypto content for $p in Org2"
        cp -r crypto-config/peerOrganizations/org2.example.com/peers/${ip}.org2.example.com/msp/* ${p}/sampleconfig/crypto
        cp -r crypto-config/peerOrganizations/org2.example.com/peers/${ip}.org2.example.com/tls/* ${p}/sampleconfig/tls/
done

echo "Deploying configuration"

for p in ${orderer[*]} ${all_peers[*]} ; do
    ip=${ips[$p]}
    ssh evgenyh@${ip} "pkill orderer; pkill peer" || echo ""
    ssh evgenyh@${ip} "rm -rf /var/hyperledger/production/*"
    ssh evgenyh@${ip} "cd /opt/gopath/src/github.com/hyperledger/fabric ; git reset HEAD --hard && git pull"
    scp -r ${p}/sampleconfig/* evgenyh@${ip}:/opt/gopath/src/github.com/hyperledger/fabric/sampleconfig/
done


echo "killing docker containers"
for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
    ssh evgenyh@${ip} "docker ps -aq | xargs docker kill &> /dev/null " || echo -n "."
    ssh evgenyh@${ip} "docker ps -aq | xargs docker rm &> /dev/null " || echo -n "."
    ssh evgenyh@${ip} "docker images | grep 'dev-' | awk '{print $3}' | xargs docker rmi &> /dev/null " || echo -n "."
done
echo ""

echo "Installing orderer"
ssh evgenyh@${ips[$orderer]} "bash -c '. ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ; make orderer && make peer'"
echo "Installing peers"
for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
	echo "Installing peer $p"
    ssh evgenyh@${ip} "bash -c '. ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ; make peer' "
done

echo "Starting orderer"
ssh evgenyh@${ips[$orderer]} " . ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ;  echo './build/bin/orderer &> orderer.out &' > start_o.sh; bash start_o.sh "
for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
    echo "Starting peer $p"
	ssh evgenyh@${ip} " . ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ;  echo './build/bin/peer node start &> $p.out &' > start.sh; bash start.sh "
done

echo "waiting for orderer and peers to be online"
while :; do
	allOnline=true
	for p in ${orderer[*]} ${all_peers[*]}; do
		if [[ `probePeerOrOrderer ${ips[$p]}` -ne 0 ]];then
			echo "$p isn't online yet"
			allOnline=false
			break;
		fi
	done
	if [ "${allOnline}" == "true" ];then
	    echo "The entire network is up"
		break;
	fi
	sleep 5
done

ORDERER_TLS="--tls true --cafile `pwd`/crypto-config/ordererOrganizations/example.com/orderers/${orderer_ip}.example.com/tls/ca.crt"
export CORE_PEER_TLS_ENABLED=true

sleep 20

exit

echo "Creating channel"
CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp CORE_PEER_LOCALMSPID=Org1MSP ./peer channel create ${ORDERER_TLS} -f example-cc.tx  -c example-cc -o ${orderer_ip}:7050

echo "Joining org1 peers to channel"
export CORE_PEER_LOCALMSPID=Org1MSP

for p in ${org1_peers[*]} ; do
    ip=${ips[$p]}
    CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org1.example.com/peers/${ip}.org1.example.com/tls/ca.crt CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/ CORE_PEER_ADDRESS=${ip}:7051 ./peer channel join -b yacov.block
done

echo "Joining org2 peers to channel"
export CORE_PEER_LOCALMSPID=Org2MSP

for p in ${org2_peers[*]} ; do
    ip=${ips[$p]}
    CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org2.example.com/peers/${ip}.org2.example.com/tls/ca.crt CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/ CORE_PEER_ADDRESS=${ip}:7051 ./peer channel join -b yacov.block
done


echo "Installing chaincode on Org1 peers"
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/
for p in  ${org1_peers[*]} ; do
    echo "Installing chaincode on $p"
    ip=${ips[$p]}
    CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org1.example.com/peers/${ip}.org1.example.com/tls/ca.crt CORE_PEER_ADDRESS=${ip}:7051 ./peer chaincode install -p github.com/hyperledger/fabric/examples/chaincode/go/chaincode_example02 -n exampleCC -v 1.0
done

echo "Installing chaincode on Org2 peers"
export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/
for p in  ${org2_peers[*]} ; do
    echo "Installing chaincode on $p"
    ip=${ips[$p]}
    CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org2.example.com/peers/${ip}.org2.example.com/tls/ca.crt CORE_PEER_ADDRESS=${ip}:7051 ./peer chaincode install -p github.com/hyperledger/fabric/examples/chaincode/go/chaincode_example02 -n exampleCC -v 1.0
done


echo "Instantiating chaincode on Org1"
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/
CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org1.example.com/peers/9.148.245.3.org1.example.com/tls/ca.crt CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_ADDRESS=9.148.245.3:7051 ./peer chaincode instantiate -n exampleCC -v 1.0 -C yacov -c '{"Args":["init","a","100","b","200"]}' -o ${orderer_ip}:7050 ${ORDERER_TLS}


echo "Instantiating chaincode on Org2"
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/
CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org2.example.com/peers/9.148.244.243.org2.example.com/tls/ca.crt CORE_PEER_LOCALMSPID=Org2MSP CORE_PEER_ADDRESS=9.148.244.243:7051 ./peer chaincode instantiate -n exampleCC -v 1.0 -C yacov -c '{"Args":["init","a","100","b","200"]}' -o ${orderer_ip}:7050 ${ORDERER_TLS}

sleep 10

echo "Querying arg 'a' on each peer of Org1"
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/
for p in  ${org1_peers[*]} ; do
    ip=${ips[$p]}
    export CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org1.example.com/peers/${ip}.org1.example.com/tls/ca.crt

    CORE_PEER_ADDRESS=${ip}:7051 ./peer chaincode query -c '{"Args":["query","a"]}' -C yacov -n exampleCC -v 1.0 ${ORDERER_TLS}
done

echo "Querying arg 'a' on each peer of Org2"
export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/
for p in  ${org2_peers[*]} ; do
    ip=${ips[$p]}
    export CORE_PEER_TLS_ROOTCERT_FILE=`pwd`/crypto-config/peerOrganizations/org2.example.com/peers/${ip}.org2.example.com/tls/ca.crt
    CORE_PEER_ADDRESS=${ip}:7051 ./peer chaincode query -c '{"Args":["query","a"]}' -C yacov -n exampleCC -v 1.0 ${ORDERER_TLS}
done

echo "Set up completed successfully"

#for i in `seq 5`; do
#        invoke ${bootPeer}
#done
#
#echo "Waiting for peers $peers to sync..."
#t1=`date +%s`
#while :; do
#	allInSync=true
#	for p in $peers ; do
#	    echo "Querying $p..."
#	    query $p | grep -q 'Query Result: 50'
#	    if [[ $? -ne 0 ]];then
#		    allInSync=false
#	    fi
#	done
#	if [ "${allInSync}" == "true" ];then
#		echo Sync took $(( $(date +%s) - $t1 ))s
#		break
#	fi
#done
