#! /usr/bin/env gnuplot

set terminal svg

set title 'Runtime comparison for sending series of single HTTP requests'

set object 1 rect from screen 0, 0, 0 to screen 1, 1, 0 behind
set object 1 rect fc  rgb "white"  fillstyle solid 1.0

set style fill solid 0.25 border -1
set style boxplot nooutliers pointtype 7
set boxwidth  0.5
set pointsize 0.5

unset key
set border 2
set xtics ("AsyncSocket" 1, "AsyncTCPConnection" 2) scale 0.0
set ytics nomirror
set ylabel 'Time required for completion in nanoseconds'

cd 'results'
results = system('ls */*.dat')
do for [result in results] {
	set output sprintf('%s.svg', result[:strlen(result)-4])

	stats result using 2
	range = 1.5 # (this is the default value of the `set style boxplot range` value)
	lower_limit = STATS_lo_quartile - range*(STATS_up_quartile - STATS_lo_quartile)
	upper_limit = STATS_up_quartile + range*(STATS_up_quartile - STATS_lo_quartile)

	set table '/tmp/gnuplot.dat'
	plot result index 0 using 2:($2 > upper_limit || $2 < lower_limit ? 1 : 0) smooth frequency
	plot result index 1 using 2:($2 > upper_limit || $2 < lower_limit ? 1 : 0) smooth frequency
	unset table

	plot result index 0 using (1):2 with boxplot,\
	     result index 1 using (2):2 with boxplot,\
	     '/tmp/gnuplot.dat' index 0 using (1):($2 > 0 ? $1 : 1/0) with points pt 6 lc rgb "grey",\
	     '/tmp/gnuplot.dat' index 1 using (2):($2 > 0 ? $1 : 1/0) with points pt 6 lc rgb "grey"
}