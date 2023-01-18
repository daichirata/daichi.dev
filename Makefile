deps:
	bundle install

serve: deps
	bundle exec jekyll serve --livereload --host 0.0.0.0 --drafts

build:
	NODE_ENV=production JEKYLL_ENV=production bundle exec jekyll build

