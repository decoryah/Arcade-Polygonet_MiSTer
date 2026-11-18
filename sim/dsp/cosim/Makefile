# Convenience wrapper: make (build), make smoke (run tests/*.txt), make fuzz
all:
	./build.sh
smoke: all
	@for f in tests/*.txt; do ./obj_dir/dsp_cosim $$f --lat 0 4 --cen 60 | tail -1; done
fuzz: all
	./fuzz.sh 1 400 4000 40
.PHONY: all smoke fuzz
