#FROM alpine:3.17
#RUN apk add --no-cache socat agetty
FROM ubuntu
RUN apt-get update
RUN apt-get install -y socat
COPY commy /bin/commy
COPY init.sh /
#RUN nohup sh -c "/init.sh &" && sleep 4
WORKDIR /app
CMD ["/bin/bash"]

