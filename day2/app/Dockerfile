# Image demo cố tình dùng base image cũ để Trivy có dữ liệu vulnerability cho lab.
# Không dùng image này cho production.
FROM alpine:3.10

RUN apk add --no-cache curl

CMD ["sh", "-c", "echo day2 supply-chain demo && sleep 3600"]
