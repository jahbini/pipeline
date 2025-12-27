#!/bin/bash
for i in $(seq 1 29); do
  echo "$i"
echo "Counter=$i"
touch ./logs/pipeline_"$i".log
rm state/*
echo "State removed"
cron_train.sh
cp ./logs/pipeline.log ./logs/pipeline_"$i".log
sleep 60
done
