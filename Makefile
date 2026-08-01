Baguette:
	./build.sh

test-web:
	node --test 'Tests/Web/**/*.test.js'

clean:
	swift package clean 2>/dev/null || true
	rm -f Baguette

.PHONY: Baguette clean test-web
