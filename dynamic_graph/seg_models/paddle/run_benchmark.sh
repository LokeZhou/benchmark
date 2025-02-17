#!bin/bash
set -xe
if [[ $# -lt 1 ]]; then
    echo "running job dict is {1: speed, 3:profiler, 6:max_batch_size}"
    echo "Usage: "
    echo "  CUDA_VISIBLE_DEVICES=0 bash $0 1|3|6 sp|mp model_name(HRnet|deeplabv3) 600(max_iter) d2s(True|False)"
    exit
fi

function _set_params(){
    index=$1
    base_batch_size=$2
    run_mode=${3:-"sp"} # Use sp for single GPU and mp for multiple GPU.
    model_name=${4}
    max_iter=${5:-"200"}
    dynamic_to_static=${6:-"False"}
    fp_mode=${7:-"fp32"}

    run_log_path=${TRAIN_LOG_DIR:-$(pwd)}
    profiler_path=${PROFILER_LOG_DIR:-$(pwd)}

    mission_name="图像分割"
    direction_id=0
    skip_steps=5
    keyword="ips:"
    keyword_loss="loss:"
    model_mode=-1
    ips_unit="images/s"

    device=${CUDA_VISIBLE_DEVICES//,/ }
    arr=($device)
    num_gpu_devices=${#arr[*]}

    log_file=${run_log_path}/dynamic_${model_name}_bs${base_batch_size}_${fp_mode}_${index}_${num_gpu_devices}_${run_mode}
    log_with_profiler=${profiler_path}/dynamic_${model_name}_bs${base_batch_size}_${fp_mode}_3_${num_gpu_devices}_${run_mode}
    profiler_path=${profiler_path}/profiler_dynamic_${model_name}_bs${base_batch_size}_${fp_mode}
    if [[ ${is_profiler} -eq 1 ]]; then log_file=${log_with_profiler}; fi
    log_parse_file=${log_file}
}

function _train(){
    export PYTHONPATH=$(pwd):{PYTHONPATH}
    export FLAGS_cudnn_exhaustive_search=1
    if [ ${model_name} = "HRnet" ]; then
        config="tests/benchmark/hrnet.yml"
    elif [ ${model_name} = "deeplabv3" ]; then
        config="tests/benchmark/deeplabv3p.yml"
    else
        echo "------------------>model_name should be HRnet or deeplabv3!"
        exit 1
    fi
    sed -i "s/^to_static_training.*/to_static_training: ${dynamic_to_static}/g" ${config}
    model_name=${model_name}_bs${base_batch_size}_${fp_mode}
    train_cmd="--config=${config}
               --iters=${max_iter}
               --batch_size ${base_batch_size}
               --learning_rate 0.01
	       --precision ${fp_mode}
               --num_workers 8
               --log_iters 5"

    if [ ${run_mode} = "sp" ]; then
        train_cmd="python -u train.py "${train_cmd}
    else
        rm -rf ./mylog
        train_cmd="python -m paddle.distributed.launch  --gpus=$CUDA_VISIBLE_DEVICES --log_dir ./mylog train.py "${train_cmd}
        log_parse_file="mylog/workerlog.0"
    fi

    echo "#################################${model_name}"
    timeout 15m ${train_cmd} > ${log_file} 2>&1
    if [ $? -ne 0 ];then
        echo -e "${model_name}, FAIL"
        export job_fail_flag=1
    else
        echo -e "${model_name}, SUCCESS"
        export job_fail_flag=0
    fi
    kill -9 `ps -ef|grep python |awk '{print $2}'`

    echo "#################################${model_name}"
    if [ ${run_mode} != "sp"  -a -d mylog ]; then
        rm ${log_file}
        cp mylog/workerlog.0 ${log_file}
    fi
}

source ${BENCHMARK_ROOT}/scripts/run_model.sh
_set_params $@
_run
