while [[ 1 ]]; do
    s=$((s + 1))
    cmd="./experiments.native --experiment Rope_mergesort_sac --sample-num $s --n 8 --num-changes 7 --test-flags"
    echo ------------------------------------------------------------------------------------------------------------
    echo `date`
    echo Sample num: $s
    echo Command: $cmd
    echo ------------------------------------------------------------------------------------------------------------ >> $0.out
    echo $cmd >> $0.out
    $cmd >> $0.out || exit
done
