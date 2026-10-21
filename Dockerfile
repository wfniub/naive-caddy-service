FROM alpine:3.20

LABEL maintainer="Edge Infrastructure Systems" \
      description="Production Caddy with NaiveProxy (sing-quic BBRv1) and Cloudflare DNS"

ARG TARGETARCH

# 安装基础证书与时区数据
RUN apk add --no-cache ca-certificates tzdata

# 从编译产物目录拷贝对应架构的可执行文件
COPY bin/caddy-${TARGETARCH} /usr/bin/caddy
RUN chmod +x /usr/bin/caddy

# 创建必要目录
RUN mkdir -p /etc/caddy/certs /data /config /var/www/html

# 内置高逼真企业云网关静态伪装页面
COPY web/index.html /var/www/html/index.html

# 默认端口声明
EXPOSE 80 443

# 设置默认启动命令
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
