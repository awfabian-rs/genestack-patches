#!/bin/bash
export DIR=ovn-backup
export TIME="$(date +"%Y-%m-%d_%H-%M")"
(
[[ -d "$DIR/$TIME" ]] || mkdir -p "$DIR/$TIME"
cd "$DIR/$TIME"
kubectl ko nb backup
kubectl ko sb backup
)
ls "$DIR/$TIME"/*
