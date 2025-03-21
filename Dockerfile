# 使用Ubuntu 22.04作为基础镜像
FROM ubuntu:22.04

# 避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# 安装必要的软件包
RUN apt-get update && \
    apt-get install -y \
    openjdk-8-jdk \
    sudo \
    expect \
    systemd \
    systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

# 配置systemd
RUN cd /lib/systemd/system/sysinit.target.wants/ && \
    ls | grep -v systemd-tmpfiles-setup.service | xargs rm -f && \
    rm -f /lib/systemd/system/multi-user.target.wants/* && \
    rm -f /etc/systemd/system/*.wants/* && \
    rm -f /lib/systemd/system/local-fs.target.wants/* && \
    rm -f /lib/systemd/system/sockets.target.wants/*udev* && \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl* && \
    rm -f /lib/systemd/system/basic.target.wants/* && \
    rm -f /lib/systemd/system/anaconda.target.wants/*

# 创建tomcat用户组和目录
RUN groupadd tomcat && \
    mkdir -p /usr/share/tomcat && \
    useradd -d /usr/share/tomcat -g tomcat -M -s /bin/bash tomcat && \
    usermod -aG sudo tomcat && \
    echo "tomcat ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 设置环境变量
ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV CATALINA_PID=/usr/share/tomcat/temp/tomcat.pid
ENV CATALINA_HOME=/usr/share/tomcat
ENV CATALINA_BASE=/usr/share/tomcat
ENV CATALINA_OPTS="-Xms512M -Xmx1024M -server -XX:+UseParallelGC"
ENV JAVA_OPTS="-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom"

# 复制和解压tomcat
COPY tomcat.tar.gz /tmp/
RUN tar xvf /tmp/tomcat.tar.gz -C /usr/share/tomcat --strip-components 1 && \
    chgrp -R tomcat /usr/share/tomcat && \
    chmod -R g+r /usr/share/tomcat/conf && \
    chmod g+x /usr/share/tomcat/conf && \
    chown -R tomcat /usr/share/tomcat/webapps/ /usr/share/tomcat/work/ /usr/share/tomcat/temp/ /usr/share/tomcat/logs/

# 安装License Server
COPY ls.bin /tmp/
RUN chmod +x /tmp/ls.bin && \
    mkdir -p /run/systemd/system && \
    echo '#!/usr/bin/expect -f\n\
set timeout -1\n\
spawn /tmp/ls.bin -i console\n\
expect {\n\
    "PRESS <ENTER> TO CONTINUE:" { send "\\r"; exp_continue }\n\
    "PRESS <ENTER> TO ACCEPT THE FOLLOWING (OK):" { send "\\r"; exp_continue }\n\
    "DO YOU ACCEPT THE TERMS OF THIS LICENSE AGREEMENT? (Y/N):" { send "Y\\r"; exp_continue }\n\
    "ENTER AN ABSOLUTE PATH, OR PRESS <ENTER> TO ACCEPT THE DEFAULT" { send "\\r"; exp_continue }\n\
    "Enter local Tomcat server path:" { send "/usr/share/tomcat\\r"; exp_continue }\n\
    "ENTER A COMMA-SEPARATED LIST OF NUMBERS REPRESENTING THE DESIRED CHOICES, OR" { send "1,2\\r"; exp_continue }\n\
    "PRESS <ENTER> TO EXIT THE INSTALLER:" { send "\\r"; exp_continue }\n\
    eof\n\
}\n' > /tmp/install_ls.exp && \
    chmod +x /tmp/install_ls.exp && \
    /tmp/install_ls.exp || true && \
    rm -f /tmp/tomcat.tar.gz /tmp/ls.bin /tmp/install_ls.exp

# 创建服务文件
RUN echo '[Unit]\n\
Description=Tomcat Server\n\
After=network.target\n\
\n\
[Service]\n\
Type=forking\n\
User=tomcat\n\
Group=tomcat\n\
Environment=JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64\n\
Environment=CATALINA_HOME=/usr/share/tomcat\n\
Environment=CATALINA_BASE=/usr/share/tomcat\n\
Environment=CATALINA_PID=/usr/share/tomcat/temp/tomcat.pid\n\
Environment=CATALINA_OPTS="-Xms512M -Xmx1024M -server -XX:+UseParallelGC"\n\
\n\
ExecStart=/usr/share/tomcat/bin/startup.sh\n\
ExecStop=/usr/share/tomcat/bin/shutdown.sh\n\
\n\
[Install]\n\
WantedBy=multi-user.target' > /etc/systemd/system/tomcat.service && \
    echo '[Unit]\n\
Description=NVIDIA License Server\n\
After=network.target tomcat.service\n\
\n\
[Service]\n\
Type=forking\n\
ExecStart=/opt/flexnetls/nvidia/startup.sh\n\
ExecStop=/opt/flexnetls/nvidia/shutdown.sh\n\
\n\
[Install]\n\
WantedBy=multi-user.target' > /etc/systemd/system/nvidia-ls.service && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /etc/systemd/system/tomcat.service /etc/systemd/system/multi-user.target.wants/tomcat.service && \
    ln -sf /etc/systemd/system/nvidia-ls.service /etc/systemd/system/multi-user.target.wants/nvidia-ls.service

# 创建安装脚本和服务
RUN echo '#!/bin/bash\n\
cd /opt/flexnetls/nvidia/server\n\
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64\n\
export JRE_HOME=/usr/lib/jvm/java-8-openjdk-amd64/jre\n\
if [ ! -f /opt/flexnetls/nvidia/.installed ]; then\n\
    chmod +x ./install-systemd.sh\n\
    ./install-systemd.sh\n\
    touch /opt/flexnetls/nvidia/.installed\n\
fi' > /usr/local/bin/install-ls.sh && \
    chmod +x /usr/local/bin/install-ls.sh && \
    echo '[Unit]\n\
Description=NVIDIA License Server Installation\n\
After=network.target\n\
Before=tomcat.service nvidia-ls.service\n\
\n\
[Service]\n\
Type=oneshot\n\
ExecStart=/usr/local/bin/install-ls.sh\n\
RemainAfterExit=yes\n\
\n\
[Install]\n\
WantedBy=multi-user.target' > /etc/systemd/system/nvidia-ls-install.service && \
    ln -sf /etc/systemd/system/nvidia-ls-install.service /etc/systemd/system/multi-user.target.wants/nvidia-ls-install.service

# 设置工作目录和端口
WORKDIR /usr/share/tomcat
EXPOSE 7070 8080

# 设置容器启动命令
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"] 