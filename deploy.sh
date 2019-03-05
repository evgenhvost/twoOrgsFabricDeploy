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

checkDir() {
    ssh nimble@$1 "ls $2 &> /dev/null || echo 'not found'" | grep -q "not found"
    if [ $? -eq 0 ];then
            echo "1"
            return
    fi
    echo "0"
}

deployFabricScript() {
        echo "Deploying script '$2' to '$1' and running it"
        scp $2 nimble@$1:$2
        ssh nimble@$1 "bash $2"
}

invoke() {
        CORE_PEER_LOCALMSPID=PeerOrg CORE_PEER_MSPCONFIGPATH=`pwd`/crypto-config/peerOrganizations/hrl.ibm.il/users/Admin@hrl.ibm.il/msp/ CORE_PEER_ADDRESS=$1:7051 ./peer chaincode invoke -c '{"Args":["invoke","a","b","10"]}' -C yacov -n exampleCC -v 1.0  --tls true --cafile `pwd`/crypto-config/ordererOrganizations/hrl.ibm.il/orderers/${orderer}.hrl.ibm.il/tls/ca.crt
}

[[ -z $GOPATH ]] && (echo "Environment variable GOPATH isn't set!"; exit 1)
FABRIC=$GOPATH/src/github.com/hyperledger/fabric
[[ -d "$FABRIC" ]] || (echo "Directory $FABRIC doesn't exist!"; exit 1)
rm -rf configtxgen peer cryptogen
for file in configtxgen peer cryptogen; do
	binary=$FABRIC/build/bin/$file
	[[ ! -f $binary ]] && ( cd $FABRIC ; make $file)
	cp $binary $file && continue
done

for file in configtxgen peer cryptogen; do
	[[ ! -f $file ]] && echo "$file isn't found, aborting!" && exit 1
done

# vms-network
org1_peers=( peer0.org1 peer1.org1 )
declare -A ips=(    ["orderer"]="9.148.244.225" \
                    ["peer0.org1"]="9.148.245.3" \
                    ["peer1.org1"]="9.148.245.10" \
                    ["peer0.org2"]="9.148.244.243" \
                    ["ca.org1"]="9.148.245.3" \
                    ["ca.org2"]="9.148.244.243" )

# public-test-network
#org1_peers=( "peer0.org1" )
#declare -A ips=(    ["orderer"]="161.156.70.125" \
#                    ["peer0.org1"]="161.156.70.114" \
#                    ["peer0.org2"]="161.156.70.120" \
#                    ["ca.org1"]="161.156.70.114" \
#                    ["ca.org2"]="161.156.70.120" )

org2_peers=( "peer0.org2" )
orderer=( orderer )

all_peers=( "${org1_peers[@]}" "${org2_peers[@]}" )
all_cas=( "ca.org1" "ca.org2" )

orderer_ip=${ips["orderer"]}
org1_ca_ip=${ips["ca.org1"]}
org2_ca_ip=${ips["ca.org2"]}

for p in ${orderer[*]} ${all_peers[*]} ; do
    ip=${ips[$p]}
    echo "Checking if fabric is installed on ${ip}"
    if [ `checkDir ${ip} /opt/gopath/src/github.com/hyperledger/fabric/` == "1" ] ; then
            echo "Didn't detect fabric installation on $p, proceeding to install fabric on it"
            deployFabricScript ${ip} "install-fabric.sh"
    else
        echo "Fabric is installed"
    fi
done

for ca in ${all_cas[*]} ; do
    ip=${ips[$ca]}
    echo "Checking if fabric-ca is installed on ${ip}"
    if [ `checkDir ${ip} "/opt/gopath/src/github.com/hyperledger/fabric-ca/"` == "1" ] ; then
            echo "Didn't detect fabric-ca installation on $ca, proceeding to install fabric-ca on it"
            deployFabricScript ${ip} "install-fabric-ca.sh"
    else
        echo "Fabric-ca is installed"
    fi
done

echo "Deleting old crypto-config generated material"
rm -rf crypto-config

for p in ${orderer[*]} ${all_peers[*]} ; do
    echo "Deleting config dir of '$p' and creating new ${p}/sampleconfig"
	rm -rf ${p}
    mkdir -p ${p}/sampleconfig/crypto
    mkdir -p ${p}/sampleconfig/tls
done

for ca in ${all_cas[*]} ; do
    echo "Deleting ca config directory '$ca' and creating new"
    rm -rf ${ca}
    mkdir ${ca}
done

echo "Generating crypto content"
./cryptogen generate --config crypto-config.yml

echo "Generating genesis block from config"
./configtxgen -profile TwoOrgsOrdererGenesis -outputBlock genesis.block -channelID system

echo "Generating channel configs"
./configtxgen -profile TwoOrgsChannel -outputCreateChannelTx example-cc.tx -channelID example-cc

PROPAGATEPEERNUM=${PROPAGATEPEERNUM:-3}
i=0
org1BootPeer=${ips[${org1_peers[0]}]}
for p in ${orderer[*]} ${org1_peers[*]} ; do
        ip=${ips[$p]}
        orgLeader=false
        orgMsp=OrdererMSP
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

mv genesis.block orderer/sampleconfig/
cp orderer.yaml orderer/sampleconfig/

echo "Copying orderer msp crypto content"
cp -r crypto-config/ordererOrganizations/example.com/orderers/${orderer_ip}.example.com/msp/* orderer/sampleconfig/crypto
cp -r crypto-config/ordererOrganizations/example.com/orderers/${orderer_ip}.example.com/tls/* orderer/sampleconfig/tls


for ORG in org1 org2 ; do
    var_name=${ORG}_ca_ip
    ca_ip=${!var_name}
    echo "Creating fabric-ca-server-config.yaml from template file for CA of org=$ORG on ip=$ca_ip"
    cat fabric-ca-server-config_template.yaml | sed "s/CA_NAME/${ca_ip}/ ; s/CA_KEY_FILE/${ca_ip}-ca-key.pem/ ; s/CERTIFICATE_FILE/${ca_ip}.$ORG.example.com-cert.pem/" > ca.$ORG/fabric-ca-server-config.yaml

    echo "Copying CA certificate for org=$ORG"
    cp -r crypto-config/peerOrganizations/${ORG}.example.com/ca/${ca_ip}.${ORG}.example.com-cert.pem ca.${ORG}/

    echo "Finding CA key for org=${ORG}"
    ca_key=`find ./crypto-config/peerOrganizations/${ORG}.example.com/ca -name "*_sk" -printf "%f" `
    echo "The found CA's key is ${ca_key}"
    cp -r crypto-config/peerOrganizations/${ORG}.example.com/ca/${ca_key} ca.${ORG}/${ca_ip}-ca-key.pem    
done 

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


echo "Killing old peers and orderer and copying new configuration"
for p in ${orderer[*]} ${all_peers[*]} ; do
    ip=${ips[$p]}
    echo "Killing $ip"
    ssh nimble@${ip} "pkill -eo -SIGKILL orderer ; pkill -eo -SIGKILL peer ; rm -rf /var/hyperledger/production/* ; cd /opt/gopath/src/github.com/hyperledger/fabric ; git reset HEAD --hard && git pull "
    scp -r ${p}/sampleconfig/* nimble@${ip}:/opt/gopath/src/github.com/hyperledger/fabric/sampleconfig/
done


for p in ${all_cas[*]} ; do
    ip=${ips[$p]}
    echo "On $p killing old fabric-ca process, deleting previous data in /bin, builidng new ca server and copying new configurations"
    ssh nimble@${ip} "pkill -efx -SIGKILL \"./fabric-ca-server start\" || echo \"No fabric-ca to kill\" ; cd /opt/gopath/src/github.com/hyperledger/fabric-ca; rm -rf bin/* ; git reset HEAD --hard && git pull ; . ~/.profile ; make fabric-ca-server"
    scp -r ${p}/* nimble@${ip}:/opt/gopath/src/github.com/hyperledger/fabric-ca/bin/
done

echo "killing docker containers"
for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
    ssh nimble@${ip} "docker ps -aq | xargs docker kill &> /dev/null " || echo -n "."
    ssh nimble@${ip} "docker ps -aq | xargs docker rm &> /dev/null " || echo -n "."
    ssh nimble@${ip} "docker images | grep 'dev-' | awk '{print $3}' | xargs docker rmi &> /dev/null " || echo -n "."
done
echo ""

echo "Remaking orderer"
ssh nimble@${orderer_ip} "bash -c '. ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ; make orderer' "

for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
	echo "Remaking peer in $p"
    ssh nimble@${ip} "bash -c '. ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric ; make peer' "
done


echo "Starting orderer"
ssh nimble@${orderer_ip} " . ~/.profile;   cd /opt/gopath/src/github.com/hyperledger/fabric ;  echo './build/bin/orderer &> orderer.out &' > start_o.sh; bash start_o.sh "

for p in ${all_peers[*]} ; do
    ip=${ips[$p]}
    echo "Starting peer $p"
	ssh nimble@${ip} " . ~/.profile;       cd /opt/gopath/src/github.com/hyperledger/fabric ;  echo './build/bin/peer node start &> $p.out &' > start.sh ; bash start.sh "
done

for p in ${all_cas[*]} ; do
    ip=${ips[$p]}
    echo "Starting fabric-ca $p"
	ssh nimble@${ip} " . ~/.profile; cd /opt/gopath/src/github.com/hyperledger/fabric-ca/bin ;  echo './fabric-ca-server start &> $p.out &' > start.sh ; bash start.sh "
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

exit

ORDERER_TLS="--tls true --cafile `pwd`/crypto-config/ordererOrganizations/example.com/orderers/${orderer_ip}.example.com/tls/ca.crt"
export CORE_PEER_TLS_ENABLED=true

sleep 20


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
