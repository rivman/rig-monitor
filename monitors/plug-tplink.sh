#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


# read power usage from smart plug
POWER_USAGE=`${BASE_DIR}/lib/tplink-smartplug.py -t ${PLUG_IP} -j '{"emeter":{"get_realtime":{}}}' | grep Received | sed 's/.*power\":\(\w\+\).*/\1/'`

if (( DEBUG == 1 )); then
	echo $RIG_ID, $POWER_USAGE
fi

# parse miner output, prepare data for influxdb ingest and filter out null tags, fields
MEASUREMENT="env_data"
TAGS="plug_type=${PLUG_TYPE},rig_id=${RIG_ID}"
FIELDS="power_usage="${POWER_USAGE}
LINE="${MEASUREMENT},${TAGS} ${FIELDS} ${RUN_TIME}"

DATA_BINARY="${DATA_BINARY}"$'\n'"${LINE}"

if (( DEBUG == 1 )); then
        echo "$DATA_BINARY"
fi
curl -i -XPOST 'http://localhost:8086/write?db=rigdata' --data-binary "${DATA_BINARY}"

IFS=$SAVEIFS
