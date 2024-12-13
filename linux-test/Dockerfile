FROM ubuntu
RUN echo 'root:root' | chpasswd
RUN echo "root root" > /etc/issue
RUN apt-get update
RUN apt-get install -y socat
COPY commy /bin/commy
COPY init.sh /
CMD ["/bin/bash"]

