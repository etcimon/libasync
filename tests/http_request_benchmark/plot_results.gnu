#! /usr/bin/env gnuplot

set terminal svg

set style line 1 lc rgb '#dd181f' lt 1 lw 0.1 pt 5 ps 0.2   # --- red
set style line 2 lc rgb '#0060ad' lt 1 lw 0.1 pt 7 ps 0.2   # --- blue

set xlabel 'Index of HTTP request'
set ylabel 'Time required for completion in nanoseconds'

set yrange [0:300000]

cd 'results'
results = system('ls *.dat')
do for [result in results] {
	set output sprintf('%s.svg', result[:strlen(result)-4])
	plot result index 0 t 'AsyncSocket' with linespoints ls 1, \
	     result index 1 t 'AsyncTCPConnection' with linespoints ls 2
}