#!/usr/bin/env bash

vm_size_is_supported() {
  case "$1" in
    Standard_NC40ads_H100_v5|Standard_NC80adis_H100_v5) return 0 ;;
    *) return 1 ;;
  esac
}

vm_size_tensor_parallel_size() {
  case "$1" in
    Standard_NC40ads_H100_v5) echo 1 ;;
    Standard_NC80adis_H100_v5) echo 2 ;;
    *) return 1 ;;
  esac
}
