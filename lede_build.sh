name: Build OpenWrt X86 Firmware
on:
  workflow_dispatch:
  schedule:
    - cron: 0 17 * * *
jobs:
  build:
    name: Compile OpenWrt X86 Firmware
    runs-on: ubuntu-22.04
    timeout-minutes: 360
    steps:
      - name: Checkout repository code
        uses: actions/checkout@v4
      - name: Show workspace files
        run: ls -la
      # 缓存dl下载源码包
      - name: Cache dl source
        id: cache_dl
        uses: actions/cache@v4
        with:
          path: lede/dl
          key: Linux-lede-dl-${{ github.sha }}
          restore-keys: |
            Linux-lede-dl-
      # 缓存ccache编译缓存
      - name: Cache ccache
        id: cache_ccache
        uses: actions/cache@v4
        with:
          path: .ccache
          key: Linux-lede-ccache-${{ github.sha }}
          restore-keys: |
            Linux-lede-ccache-
      # 打印缓存命中状态
      - name: Print cache hit status
        run: |
          echo "DL Cache hit = ${{ steps.cache_dl.outputs.cache-hit }}"
          echo "CCACHE Cache hit = ${{ steps.cache_ccache.outputs.cache-hit }}"
      # 执行编译脚本
      - name: Run build script
        run: |
          export FORCE_UNSAFE_CONFIGURE=1
          chmod +x ./lede_build.sh
          ./lede_build.sh
      # 清理完成后查看磁盘空间
      - name: Show disk space after cleanup
        run: df -h
      # 获取日期，用于artifact命名
      - name: Get build date
        run: echo "BUILD_DATE=$(date +%Y%m%d)" >> $GITHUB_ENV
      # 把固件zip复制到当前目录，避免嵌套bin文件夹
      - name: Copy firmware to workspace root
        run: cp firmware/*.zip ./ || true
      # 上传固件
      - name: Upload firmware artifact
        uses: actions/upload-artifact@v4
        with:
          name: openwrt_x86_${{ env.BUILD_DATE }}
          path: ./*.zip
          retention-days: 30
          if-no-files-found: ignore
