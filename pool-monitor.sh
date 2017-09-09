#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $BASE_DIR

. ${BASE_DIR}/conf/rig-monitor.conf
. ${BASE_DIR}/lib/functions

# epoch RUN_TIME
RUN_TIME=`date +%s`

if [ -f ${BASE_DIR}/run/POOL_LOCK ]; then
    	echo "pool-monitor process still running! Exiting..."
	exit
else
	touch  ${BASE_DIR}/run/POOL_LOCK
fi

if [ "$1" == "-trace" ];then
	set -x
fi

SAVEIFS=$IFS

# FETCH POOL DATA VIA HTTP
for POOL_LINE in "${POOL_LIST[@]}"
do
	IFS=$',' read POOL_TYPE CRYPTO LABEL BASE_API_URL API_TOKEN WALLET_ADDR <<<${POOL_LINE}
	#echo $POOL_TYPE $LABEL $BASE_API_URL $API_TOKEN $WALLET_ADDR

	if [ "$POOL_TYPE" == "ETHERMINE" ]; then

		STATS_URL="${BASE_API_URL}/miner/${WALLET_ADDR}/currentStats"
		echo "curl \"$STATS_URL\""
		CURL_OUTPUT=`curl -s "${STATS_URL}" | jq -r '.data'`
		# echo $CURL_OUTPUT | jq -r '.'
		if [ "$CURL_OUTPUT" == "NO DATA" ]; then
			echo "NO DATA FOUND"
		else
			echo $CURL_OUTPUT  | jq --arg LABEL $LABEL -r '. | .+ {"label": $LABEL, "report": "currentStats"} |[.time,.label,.report,.lastSeen,.reportedHashrate,.currentHashrate,.validShares,.invalidShares,.staleShares,.averageHashrate,.activeWorkers,.unpaid,.unconfirmed,.coinsPerMin,.usdPerMin,.btcPerMin] | @csv' |sed 's/\"//g' >> ${DATA_DIR}/$POOL_DATA_FILE
		fi

		PAYOUT_URL="${BASE_API_URL}/miner/${WALLET_ADDR}/payouts"
		echo "curl \"$PAYOUT_URL\""
		CURL_OUTPUT=`curl -s "${PAYOUT_URL}" | jq -r '.data[]'`
		#echo $CURL_OUTPUT
		if [ "$CURL_OUTPUT" == "" ]; then
			echo "NO DATA FOUND"
		else
			echo $CURL_OUTPUT  | jq --arg LABEL $LABEL --arg RUN_TIME $RUN_TIME -r '. | .+ {"label": $LABEL, "report": "payouts", "run_time": $RUN_TIME} | [.run_time,.paidOn,.label,.report,.start,.end,.amount,.txHash] | @csv' |sed 's/\"//g' >> ${DATA_DIR}/$POOL_DATA_FILE
		fi

	elif [ "$POOL_TYPE" == "MPOS" ]; then

		DASHBOARD_URL="${BASE_API_URL}/index.php?page=api&action=getdashboarddata&api_key=${API_TOKEN}"
		echo "curl \"$DASHBOARD_URL\""
		CURL_OUTPUT=`curl -s "${DASHBOARD_URL}"`
		#echo $CURL_OUTPUT 
		if [ "$CURL_OUTPUT" == "Access denied" ]; then
			echo "NO DATA FOUND"
		else
			echo $CURL_OUTPUT  | jq --arg LABEL $LABEL --arg RUN_TIME $RUN_TIME -r '.getdashboarddata.data | .+ {"label": $LABEL, "report": "getdashboarddata_stats", "run_time": $RUN_TIME} | [.run_time,.label,.report,.raw.personal.hashrate,.raw.pool.hashrate,.raw.network.hashrate,.personal.shares.valid,.personal.shares.invalid,.personal.shares.unpaid,.balance.confirmed,.balance.unconfirmed] | @csv' |sed 's/\"//g' >>  ${DATA_DIR}/$POOL_DATA_FILE
			echo $CURL_OUTPUT  | jq --arg LABEL $LABEL -r '.getdashboarddata.data.recent_credits[] | .+ {"label": $LABEL, "report": "getdashboarddata_payouts"} | [.date,.label,.report,.amount] | @csv' |sed 's/\"//g'>> ${DATA_DIR}/$POOL_DATA_FILE
		fi

	elif [ "$POOL_TYPE" == "NANOPOOL" ]; then

		GENERALINFO_URL="${BASE_API_URL}/v1/${CRYPTO,,}/user/${WALLET_ADDR}"
		echo "curl \"$GENERALINFO_URL\""
		CURL_OUTPUT=`curl -s "${GENERALINFO_URL}" | jq -r '.'`
		CURL_STATUS=`echo $CURL_OUTPUT | jq -r '.status'`
		#echo $CURL_STATUS 
		if [ "$CURL_STATUS" == "false" ]; then
			echo "NO DATA FOUND"
		else
			CURL_OUTPUT=`echo $CURL_OUTPUT | jq -r '.data'`
			#echo $CURL_OUTPUT
			echo $CURL_OUTPUT  | jq --arg LABEL $LABEL --arg RUN_TIME $RUN_TIME -r '. | .+ {"label": $LABEL, "report": "generalinfo", "run_time": $RUN_TIME} | [.run_time,.label,.report,.hashrate,.avgHashrate.h1,.avgHashrate.h3,.avgHashrate.h6,.avgHashrate.h12,.avgHashrate.h24,.balance,.unconfirmed_balance] | @csv' |sed 's/\"//g' >>  ${DATA_DIR}/$POOL_DATA_FILE
		fi


		PAYMENTS_URL="${BASE_API_URL}/v1/${CRYPTO,,}/payments/${WALLET_ADDR}"
		echo "curl \"$PAYMENTS_URL\""
		CURL_OUTPUT=`curl -s "${PAYMENTS_URL}" | jq -r '.'`
		CURL_STATUS=`echo $CURL_OUTPUT | jq -r '.data[]'`
		#echo $CURL_STATUS 
		if [ "$CURL_STATUS" == "" ]; then
			echo "NO DATA FOUND"
		else
			echo $CURL_OUTPUT | jq --arg LABEL $LABEL --arg RUN_TIME $RUN_TIME -r '.data[] | .+ {"label": $LABEL, "report": "payments", "run_time": $RUN_TIME} | [.run_time,.date,.label,.report,.txHash,.amount,.confirmed] | @csv' |sed 's/\"//g' >>  ${DATA_DIR}/$POOL_DATA_FILE
		fi

	fi
done

# INGEST POOL DATA
if [ -f ${DATA_DIR}/${POOL_DATA_FILE} ] ; then

	echo "ingesting pool data..."

	# sort and remove duplicate entries in DATA file
	sort --field-separator=',' ${DATA_DIR}/${POOL_DATA_FILE} | uniq > ${DATA_DIR}/${POOL_DATA_FILE}.tmp
	mv ${DATA_DIR}/${POOL_DATA_FILE}.tmp ${DATA_DIR}/${POOL_DATA_FILE}

	for POOL_LINE in "${POOL_LIST[@]}"; do
		IFS=$',' read POOL_TYPE CRYPO LABEL BASE_API_URL API_TOKEN WALLET_ADDR <<<${POOL_LINE}

		BOOKKEEPING_RECORD_NAME="${LABEL}_POOL_LAST_RECORD"

		LAST_RECORD=$(bookkeeping $BOOKKEEPING_RECORD_NAME)
		echo "last ingested $LABEL pool stats: $LAST_RECORD"

		if [ "$POOL_TYPE" == "ETHERMINE" ]; then
			# filter out old records using LABEL and LAST_RECORD as filters
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=currentStats last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_ethermine_stats.tmp
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=payouts last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_ethermine_payouts.tmp

			mysql -vvv -u ${GRAFANA_DB_USER} -p${GRAFANA_DB_PWD}  --local-infile rigdata < ${SQL_SCRIPTS}/ingest_ethermine_data.sql

		elif [ "$POOL_TYPE" == "MPOS" ]; then
			# filter out records using report and LAST_RECORD as filters
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=getdashboarddata_stats last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_getdashboarddata_stats.tmp
			# filter out records using report and LAST_RECORD as filters
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=getdashboarddata_payouts last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_getdashboarddata_payouts.tmp

			mysql -vvv -u ${GRAFANA_DB_USER} -p${GRAFANA_DB_PWD}  --local-infile rigdata < ${SQL_SCRIPTS}/ingest_mpos_data.sql

		elif [ "$POOL_TYPE" == "NANOPOOL" ]; then
			# filter out records using report and LAST_RECORD as filters
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=generalinfo last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_generalinfo.tmp
			# filter out records using report and LAST_RECORD as filters
       			awk -f ${BASE_DIR}/awk/filter_pool_records_by_tag.awk -v label=$LABEL report=payments last_record=$LAST_RECORD ${DATA_DIR}/${POOL_DATA_FILE} > ${TMP_DIR}/${POOL_TYPE}_payments.tmp

			mysql -vvv -u ${GRAFANA_DB_USER} -p${GRAFANA_DB_PWD}  --local-infile rigdata < ${SQL_SCRIPTS}/ingest_nanopool_data.sql

		fi

		# update bookkeeping file
		$(bookkeeping $BOOKKEEPING_RECORD_NAME $RUN_TIME)
		echo "updating last ingested $LABEL pool stats to: $RUN_TIME"
	done




fi

IFS=$SAVEIFS

rm ${BASE_DIR}/run/POOL_LOCK 

