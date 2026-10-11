GO ?= go

BACKEND_DIR := backend
DIST_DIR    := dist
LAMBDAS     := api inbound

# zip のハッシュを毎回同じにするため、バイナリの mtime をこの日時に固定する（touch -t 形式、UTC）。
ZIP_MTIME := 198001010000.00

LAMBDA_ZIPS := $(foreach fn,$(LAMBDAS),$(DIST_DIR)/$(fn).zip)

.PHONY: lambda-build clean FORCE

## lambda-build: backend/cmd/{api,inbound} を arm64 でビルドし dist/{api,inbound}.zip を作る
lambda-build: $(LAMBDA_ZIPS)

# go build 自体がキャッシュを効かせるので、毎回ビルドして zip を作り直す。
$(DIST_DIR)/%.zip: FORCE
	@mkdir -p $(DIST_DIR)/$*
	cd $(BACKEND_DIR) && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		$(GO) build -trimpath -buildvcs=false -tags lambda.norpc -ldflags="-s -w" \
		-o $(CURDIR)/$(DIST_DIR)/$*/bootstrap ./cmd/$*
	chmod 0755 $(DIST_DIR)/$*/bootstrap
	TZ=UTC touch -t $(ZIP_MTIME) $(DIST_DIR)/$*/bootstrap
	rm -f $@
	cd $(DIST_DIR)/$* && TZ=UTC zip -q -X -D $(CURDIR)/$@ bootstrap

FORCE:

## clean: ビルド成果物を削除する
clean:
	rm -rf $(DIST_DIR)
