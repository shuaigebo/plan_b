#!/bin/sh

source /jffs/softcenter/scripts/ss_base.sh

LOCK_FILE=/tmp/online_update.lock
LOG_FILE=/tmp/upload/ss_log.txt
CONFIG_FILE=/jffs/softcenter/ss/ss.json
BACKUP_FILE_TMP=/tmp/ss_conf_tmp.sh
BACKUP_FILE=/tmp/ss_conf.sh
KEY_WORDS_1=$(echo $ss_basic_exclude | sed 's/,$//g' | sed 's/,/|/g')
KEY_WORDS_2=$(echo $ss_basic_include | sed 's/,$//g' | sed 's/,/|/g')
DEL_SUBSCRIBE=0
SOCKS_FLAG=0
NODES_SEQ=$(export -p | grep ssconf_basic_ | grep _name_ | cut -d "=" -f1 | cut -d "_" -f4 | sort -n)
NODES_SEQ=$(echo $NODES_SEQ | sed 's/[[:space:]]/|/g')
NODE_INDEX=${NODES_SEQ##*|}

# 一个节点里可能有的所有信息
readonly PREFIX="ssconf_basic_name_
				ssconf_basic_server_
				ssconf_basic_mode_
				ssconf_basic_method_
				ssconf_basic_password_
				ssconf_basic_port_
				ssconf_basic_ss_obfs_
				ssconf_basic_ss_obfs_host_
				ssconf_basic_ssr_obfs_
				ssconf_basic_ssr_obfs_param_
				ssconf_basic_ssr_protocol_
				ssconf_basic_ssr_protocol_param_
				ssconf_basic_koolgame_udp_
				ssconf_basic_use_kcp_
				ssconf_basic_use_lb_
				ssconf_basic_lbmode_
				ssconf_basic_weight_
				ssconf_basic_group_
				ssconf_basic_v2ray_use_json_
				ssconf_basic_v2ray_uuid_
				ssconf_basic_v2ray_alterid_
				ssconf_basic_v2ray_security_
				ssconf_basic_v2ray_network_
				ssconf_basic_v2ray_headtype_tcp_
				ssconf_basic_v2ray_headtype_kcp_
				ssconf_basic_v2ray_network_path_
				ssconf_basic_v2ray_network_host_
				ssconf_basic_v2ray_network_security_
				ssconf_basic_v2ray_mux_enable_
				ssconf_basic_v2ray_mux_concurrency_
				ssconf_basic_v2ray_json_
				ssconf_basic_v2ray_vmessvless_
				ssconf_basic_v2ray_fingerprint_
				ssconf_basic_ss_v2ray_
				ssconf_basic_ss_v2ray_opts_
				ssconf_basic_type_
				ssconf_basic_trojan_mp_enable_
				ssconf_basic_trojan_mulprocess_
				ssconf_basic_trojan_sni_
				ssconf_basic_ssl_verify_enable_"

set_lock(){
	exec 233>"$LOCK_FILE"
	flock -n 233 || {
		local PID1=$$
		local PID2=$(ps|grep -w "ss_online_update.sh"|grep -vw "grep"|grep -vw ${PID1})
		if [ -n "${PID2}" ];then
			echo_date "订阅脚本已经在运行，请稍候再试！"
			exit 1			
		else
			rm -rf $LOCK_FILE
		fi

	}
}

unset_lock(){
	flock -u 233
	rm -rf "$LOCK_FILE"
}

trim_string() {
    trim=${1#${1%%[![:space:]]*}}
    trim=${trim%${trim##*[![:space:]]}}
    printf '%s\n' "$trim"
}

get_type_name() {
	case "$1" in
		0)
			echo "SS"
		;;
		1)
			echo "SSR"
		;;
		2)
			echo "v2ray"
		;;
		3)
			echo "trojan"
		;;
	esac
}

# 清除已有的所有节点配置
remove_all_node(){
	echo_date "删除所有节点信息！"
	confs=$(export -p | grep ssconf_basic_ | cut -d "=" -f1)
	for conf in $confs
	do
		echo_date "移除$conf"
		dbus remove $conf
	done
}

# 删除所有订阅节点
remove_sub_node(){
	echo_date "删除所有订阅节点信息...自添加的节点不受影响！"
	remove_nus=$(export -p | grep ssconf_basic_ | grep _group_ | cut -d "=" -f1 | cut -d "_" -f4 | sort -n)
	if [ -z "$remove_nus" ]; then
		echo_date "节点列表内不存在任何订阅来源节点，退出！"
		return 1
	fi
	for remove_nu in $remove_nus
	do
		echo_date "移除第$remove_nu节点：【$(eval echo \$ssconf_basic_name_${remove_nu})】"
		for item in $PREFIX
		do
			dbus remove ${item}${remove_nu}
		done
	done
	echo_date "所有订阅节点信息已经成功删除！"
}

prepare(){
	echo_date "开始节点数据检查..."
	local REASON=0
	local SEQ_NU=$(echo ${NODES_SEQ} | tr ' ' '\n' | wc -l)
	local MAX_NU=${NODE_INDEX}
	local KEY_NU=$(export -p | grep ssconf_basic | cut -d "=" -f1 | sed '/^$/d' | wc -l)
	local VAL_NU=$(export -p | grep ssconf_basic | cut -d "=" -f2 | sed '/^$/d' | wc -l)

	echo_date "最大节点序号：$MAX_NU"
	echo_date "共有节点数量：$SEQ_NU"

	# 如果[节点数量 ${SEQ_NU}]不等于[最大节点序号 ${MAX_NU}]，说明节点排序是不正确的。
	if [ ${SEQ_NU} -ne ${MAX_NU} ]; then
		let REASON+=1
		echo_date "节点顺序不正确，需要调整！"
	fi

	# 如果key的数量不等于value的数量，说明有些key储存了空值，需要清理一下。
	if [ ${KEY_NU} -ne ${VAL_NU} ]; then
		let REASON+=2
		echo_date "节点配置有残余值，需要清理！"
	fi

	if [ $REASON == "1" -o $REASON == "3" ]; then
		# 提取干净的节点配置，并重新排序，现在web界面里添加/删除节点后会自动排序，所以以下基本不会运行到
		echo_date "备份所有节点信息并重新排序..."
		echo_date "如果节点数量过多，此处可能需要等待较长时间，请耐心等待..."
		rm -rf $BACKUP_FILE_TMP
		rm -rf $BACKUP_FILE
		local i=1
		export -p | grep ssconf_basic_name_ | awk -F"=" '{print $1}' | awk -F"_" '{print $NF}' | sort -n | while read nu
		do
			for item in $PREFIX; do
				#{
					local tmp=$(eval echo \$${item}${nu})
					if [ -n "${tmp}" ]; then
						echo "export ${item}${i}=\"${tmp}\"" >> $BACKUP_FILE_TMP
					fi
				#} &
			done
			if [ "$nu" == "$ssconf_basic_node" ]; then
				echo "export ssconf_basic_node=\"$i\"" >> $BACKUP_FILE_TMP
			fi
			if [ -n "$ss_basic_udp_node" -a "$nu" == "$ss_basic_udp_node" ]; then
				echo "export ss_basic_udp_node=\"$i\"" >> $BACKUP_FILE_TMP
			fi
			let i+=1
		done

		cat > $BACKUP_FILE <<-EOF
			#!/bin/sh
			source /jffs/softcenter/scripts/base.sh
			#------------------------
			confs=\$(dbus list ssconf_basic_ | cut -d "=" -f 1)
			for conf in \$confs
			do
			    dbus remove \$conf
			done
			usleep 300000
			#------------------------
		EOF

		cat $BACKUP_FILE_TMP | \
		awk -F"=" '{print $0"|"$1}' | \
		awk -F"_" '{print $NF"|"$0}' | \
		sort -t "|" -nk1,1 | \
		awk -F"|" '{print $2}' | \
		sed 's/export/dbus set/g' | \
		sed '1 i\#------------------------' \
		>> $BACKUP_FILE
		
		echo_date "备份完毕，开始调整..."
		# 2 应用提取的干净的节点配置
		chmod +x $BACKUP_FILE
		sh $BACKUP_FILE
		echo_date "节点调整完毕！"
	elif [ $REASON == "2" ]; then
		# 提取干净的节点配置
		echo_date "备份所有节点信息"
		rm -rf $BACKUP_FILE
		cat > $BACKUP_FILE <<-EOF
			#!/bin/sh
			source /jffs/softcenter/scripts/base.sh
			#------------------------
			confs=\$(dbus list ssconf_basic_ | cut -d "=" -f 1)
			for conf in \$confs
			do
			    dbus remove \$conf
			done
			usleep 300000
			#------------------------
		EOF
		
		local KEY="$(echo ${PREFIX} | sed 's/[[:space:]]/|/g')"
		export -p | \
		grep "ssconf_basic" | \
		awk -F"=" '{print $0"|"$1}' | \
		awk -F"_" '{print $NF"|"$0}' | \
		sort -t "|" -nk1,1 | \
		awk -F"|" '{print $2}'| \
		grep -E ${KEY} | \
		sed 's/^export/dbus set/g' | \
		sed "s/='/=\"/g" | \
		sed "s/'/\"/g" | \
		sed '/=""$/d' \
		>> $BACKUP_FILE

		echo dbus set ss_basic_udp_node=\"${ss_basic_udp_node}\" >> $BACKUP_FILE
		echo dbus set ssconf_basic_node=\"${ssconf_basic_node}\" >> $BACKUP_FILE

		echo_date "备份完毕"
		# 应用提取的干净的节点配置
		chmod +x $BACKUP_FILE
		sh $BACKUP_FILE
		echo_date "调整完毕！节点信息备份在/jffs/softcenter/configs/ss_conf.sh"
	else
		echo_date "节点顺序正确，节点配置信息OK！无需调整！"
	fi
}

decode_url_link(){
	local link=$1
	local len=$(echo $link | wc -L)
	local mod4=$(($len%4))
	if [ "$mod4" -gt "0" ]; then
		local var="===="
		local newlink=${link}${var:$mod4}
		echo -n "$newlink" | sed 's/-/+/g; s/_/\//g' | base64 -d 2>/dev/null
	else
		echo -n "$link" | sed 's/-/+/g; s/_/\//g' | base64 -d 2>/dev/null
	fi
}

add_ssr_nodes_offline(){
	# usleep 100000
	let NODE_INDEX+=1
	dbus set ssconf_basic_name_$NODE_INDEX=$remarks
	dbus set ssconf_basic_mode_$NODE_INDEX=$ssr_subscribe_mode
	dbus set ssconf_basic_server_$NODE_INDEX=$server
	dbus set ssconf_basic_port_$NODE_INDEX=$server_port
	dbus set ssconf_basic_ssr_protocol_$NODE_INDEX=$protocol
	dbus set ssconf_basic_ssr_protocol_param_$NODE_INDEX=$protoparam
	dbus set ssconf_basic_method_$NODE_INDEX=$encrypt_method
	dbus set ssconf_basic_ssr_obfs_$NODE_INDEX=$obfs
	dbus set ssconf_basic_type_$NODE_INDEX="1"
	dbus set ssconf_basic_ssr_obfs_param_$NODE_INDEX=$obfsparam
	dbus set ssconf_basic_password_$NODE_INDEX=$password
	echo_date "SSR节点：新增加【$remarks】到节点列表第 $NODE_INDEX 位。"
}

update_ss_config(){
	isadded_server=$(cat /tmp/all_localservers.txt | grep -w $group_base64 | awk '{print $1}' | grep -c $server_base64|head -n1)
	if [ "$isadded_server" == "0" ]; then
		add_ss_servers
		let addnum+=1
	else
		# 如果在本地的订阅节点中已经有该节点（用group和server去判断），检测下配置是否更改，如果更改，则更新配置
		local index=$(cat /tmp/all_localservers.txt| grep $group_base64 | grep $server_base64 |awk '{print $4}'|head -n1)

		local i=0
		dbus set ssconf_basic_mode_$index="$ssr_subscribe_mode"
		local_remarks=$(dbus get ssconf_basic_name_$index)
		#echo $local_remarks
		[ "$local_remarks" != "$remarks" ] && dbus set ssconf_basic_name_$index=$remarks && let i+=1

		local_server=$(dbus get ssconf_basic_server_$index)
		#echo $local_server
		[ "$local_server" != "$server" ] && dbus set ssconf_basic_server_$index=$server && let i+=1

		local_server_port=$(dbus get ssconf_basic_port_$index)
		#echo $local_server_port
		[ "$local_server_port" != "$server_port" ] && dbus set ssconf_basic_port_$index=$server_port && let i+=1

		local_password=$(dbus get ssconf_basic_password_$index)
		#echo $local_password
		[ "$local_password" != "$password" ] && dbus set ssconf_basic_password_$index=$password && let i+=1

		local_encrypt_method=$(dbus get ssconf_basic_method_$index)
		[ "$local_encrypt_method" != "$encrypt_method" ] && dbus set ssconf_basic_method_$index=$encrypt_method && let i+=1
		
		local_ss_obfs_tmp=$(dbus get ssconf_basic_ss_obfs_$index)
		[ "$local_ss_obfs_tmp" != "$ss_obfs_tmp" ] && dbus set ssconf_basic_ss_obfs_$index=$ss_obfs_tmp && let i+=1
		
		local_ss_obfs_host=$(dbus get ssconf_basic_ss_obfs_host_$index)
		[ "$local_ss_obfs_host" != "$ss_obfs_host" ] && dbus set ssconf_basic_ss_obfs_host_$index=$ss_obfs_host && let i+=1
		
		local_ss_v2ray_tmp=$(dbus get ssconf_basic_ss_v2ray_$index)
		[ "$local_ss_v2ray_tmp" != "$ss_v2ray_tmp" ] && dbus set ssconf_basic_ss_v2ray_$index=$ss_v2ray_tmp && let i+=1

		#echo $i
		if [ "$i" -gt "0" ];then
			echo_date "修改 ss 节点：【$remarks】" && let updatenum+=1
		else
			echo_date "ss 节点：【$remarks】 参数未发生变化，跳过！"
		fi
	fi


}
add_ss_servers(){
	NODE_INDEX=$(($(dbus list ssconf_basic_|grep _name_ | cut -d "=" -f1|cut -d "_" -f4|sort -rn|head -n1)+1))
	echo_date "添加 ss 节点：$remarks"
	[ -z "$1" ] && dbus set ssconf_basic_group_$NODE_INDEX=$group
	dbus set ssconf_basic_name_$NODE_INDEX=$remarks
	dbus set ssconf_basic_mode_$NODE_INDEX=$ssr_subscribe_mode
	dbus set ssconf_basic_server_$NODE_INDEX=$server
	dbus set ssconf_basic_port_$NODE_INDEX=$server_port
	dbus set ssconf_basic_method_$NODE_INDEX=$encrypt_method
	dbus set ssconf_basic_password_$NODE_INDEX=$password
	dbus set ssconf_basic_type_$NODE_INDEX="0"
	dbus set ssconf_basic_ss_obfs_$NODE_INDEX=$ss_obfs_tmp	
	dbus set ssconf_basic_ss_obfs_host_$NODE_INDEX=$ss_obfs_host
	dbus set ssconf_basic_ss_v2ray_$NODE_INDEX=$ss_v2ray_tmp

	echo_date "SS节点：新增加【$remarks】到节点列表第 $NODE_INDEX 位。"
	#初始化
	encrypt_method=""
	ss_obfs_tmp="0"
	ss_v2ray_tmp="0"
	ss_v2ray_opts_tmp=""
	ss_obfs_host=""
}
get_ss_config(){
	decode_link=$1
	server=$(echo "${decode_link#*@}" |awk -F'[:]' '{print $1}')
	server_port=$(echo "${decode_link#*@}" |awk -F'[:/?]' '{print $2}')
	method_password=$(echo "$decode_link" |awk -F'@' '{print $1}')
	if [ -z "$(echo "$method_password"|grep ":")" ];then
		method_password=$(echo "$method_password"| sed 's/-/+/g; s/_/\//g')
		method_password=$(decode_url_link $(echo "$method_password"))
	fi
	encrypt_method=$(echo "$method_password" |awk -F':' '{print $1}')
	password=$(echo "$method_password" |awk -F':' '{print $2}')
	password=$(echo $password | base64_encode)
	#参数获值
	plugin=$(echo "$decode_link" |awk -F'?' '{print $2}')
	#去掉无plugin但是有group=造成误取值
	
	plugin=$(echo "$plugin" |awk -F'group' '{print $1}')
	if [ -n "$plugin" ];then
		ss_obfs_tmp=$(echo "$plugin" | awk -F'obfs=' '{print $2}' | awk -F';' '{print $1}')
		case "$ss_obfs_tmp" in
		tls)
			ss_obfs_host=$(echo "$plugin" | awk -F'obfs=' '{print $2}' | awk -F';' '{print $2}' | awk -F'&' '{print $1}' | awk -F'obfs-host=' '{print $2}')
			ss_v2ray_tmp="0"
			ss_v2ray_opts_tmp=""
			;;
		http)
			ss_obfs_host=$(echo "$plugin" | awk -F'obfs=' '{print $2}' | awk -F';' '{print $2}' | awk -F'&' '{print $1}' | awk -F'obfs-host=' '{print $2}')
			ss_v2ray_tmp="0"
			ss_v2ray_opts_tmp=""
			;;
		kcp)
			
			;;
		esac
	else
		ss_obfs_tmp="0"
		ss_v2ray_tmp="0"
		ss_v2ray_opts_tmp=""
	fi
	

	[ -n "$group" ] && group_base64=`echo $group | base64_encode | sed 's/ -//g'`
	[ -n "$server" ] && server_base64=`echo $server | base64_encode | sed 's/ -//g'`
	#把全部服务器节点写入文件 /usr/share/shadowsocks/serverconfig/all_onlineservers
	[ -n "$group" ] && [ -n "$server" ] && echo $server_base64 $group_base64 >> /tmp/all_subscservers.txt
	echo "$group" >> /tmp/all_group_info.txt
	[ -n "$group" ] && return 0 || return 1
}

get_trojan_config(){
	decode_link=$1
	server=$(echo "$decode_link" |awk -F':' '{print $1}'|awk -F'@' '{print $2}')
	server_port=$(echo "$decode_link" |awk -F':' '{print $2}' | awk -F'?' '{print $1}')
	password=$(echo "$decode_link" |awk -F':' '{print $1}'|awk -F'@' '{print $1}')
	password=`echo $password|base64_encode`
	sni=$(echo "$decode_link" |awk -F'sni=' '{print $2}' | awk -F'#' '{print $1}')
	echo_date "服务器：$server"
	echo_date "端口：$server_port"
	echo_date "密码：$password"
	echo_date "sni：$sni"

	[ -n "$group" ] && group_base64=`echo $group | base64_encode | sed 's/ -//g'`
	[ -n "$server" ] && server_base64=`echo $server | base64_encode | sed 's/ -//g'`
	#把全部服务器节点写入文件 /usr/share/shadowsocks/serverconfig/all_onlineservers
	[ -n "$group" ] && [ -n "$server" ] && echo $server_base64 $group_base64 >> /tmp/all_subscservers.txt
	#echo ------
	#echo group: $group
	#echo remarks: $remarks
	#echo server: $server
	#echo server_port: $server_port
	#echo password: $password
	#echo ------
	echo "$group" >> /tmp/all_group_info.txt
	[ -n "$group" ] && return 0 || return 1
}

add_trojan_servers(){
	trojanindex=$(($(dbus list ssconf_basic_|grep _name_ | cut -d "=" -f1|cut -d "_" -f4|sort -rn|head -n1)+1))
	echo_date "添加 Trojan 节点：$remarks" >> $LOG_FILE
	[ -z "$1" ] && dbus set ssconf_basic_group_$trojanindex=$group
	dbus set ssconf_basic_name_$trojanindex=$remarks
	dbus set ssconf_basic_mode_$trojanindex=$ssr_subscribe_mode
	dbus set ssconf_basic_server_$trojanindex=$server
	dbus set ssconf_basic_port_$trojanindex=$server_port
	dbus set ssconf_basic_password_$trojanindex=$password
	dbus set ssconf_basic_type_$trojanindex="3"
	[ -n "$sni" ] && dbus set ssconf_basic_trojan_sni_$trojanindex="$sni" || dbus set ssconf_basic_trojan_sni_$trojanindex=""
	echo_date "Trojan 节点：新增加 【$remarks】 到节点列表第 $trojanindex 位。" >> $LOG_FILE
}

update_trojan_config(){
	isadded_server=$(cat /tmp/all_localservers.txt | grep -w $group_base64 | awk '{print $1}' | grep -c $server_base64|head -n1)
	if [ "$isadded_server" == "0" ]; then
		add_trojan_servers
		let addnum+=1
	else
		# 如果在本地的订阅节点中已经有该节点（用group和server去判断），检测下配置是否更改，如果更改，则更新配置
		local index=$(cat /tmp/all_localservers.txt| grep $group_base64 | grep $server_base64 |awk '{print $4}'|head -n1)

		local i=0
		dbus set ssconf_basic_mode_$index="$ssr_subscribe_mode"
		local_remarks=$(dbus get ssconf_basic_name_$index)
		[ "$local_remarks" != "$remarks" ] && dbus set ssconf_basic_name_$index=$remarks && let i+=1
		local_server=$(dbus get ssconf_basic_server_$index)
		[ "$local_server" != "$server" ] && dbus set ssconf_basic_server_$index=$server && let i+=1
		local_server_port=$(dbus get ssconf_basic_port_$index)
		[ "$local_server_port" != "$server_port" ] && dbus set ssconf_basic_port_$index=$server_port && let i+=1
		local_password=$(dbus get ssconf_basic_password_$index)
		[ "$local_password" != "$password" ] && dbus set ssconf_basic_password_$index=$password && let i+=1

		local_sni=$(dbus get ssconf_basic_trojan_sni_$index)
		[ "$local_sni" != "$sni" ] && dbus set ssconf_basic_trojan_sni_$index=$sni && let i+=1

		if [ "$i" -gt "0" ];then
			echo_date "修改 Trojan 节点：【$remarks】" && let updatenum+=1
			echo_date "修改 Trojan 节点：【$remarks】" >> $LOG_FILE
		else
			echo_date "Trojan 节点：【$remarks】 参数未发生变化，跳过！" >> $LOG_FILE
		fi
	fi
}

get_v2ray_remote_config(){
	decode_link="$1"
	v2ray_group="$2"
	v2ray_v=$(echo "$decode_link" | jq -r .v)
	v2ray_ps=$(echo "$decode_link" | jq -r .ps | sed 's/[ \t]*//g')
	v2ray_add=$(echo "$decode_link" | jq -r .add | sed 's/[ \t]*//g')
	v2ray_port=$(echo "$decode_link" | jq -r .port | sed 's/[ \t]*//g')
	v2ray_id=$(echo "$decode_link" | jq -r .id | sed 's/[ \t]*//g')
	v2ray_aid=$(echo "$decode_link" | jq -r .aid | sed 's/[ \t]*//g')
	v2ray_net=$(echo "$decode_link" | jq -r .net)
	v2ray_type=$(echo "$decode_link" | jq -r .type)
	v2ray_tls_tmp=$(echo "$decode_link" | jq -r .tls)
	[ "$v2ray_tls_tmp"x == "tls"x ] && v2ray_tls="tls" || v2ray_tls="none"
	
	if [ "$v2ray_v" == "2" ]; then
		# "new format"
		v2ray_path=$(echo "$decode_link" | jq -r .path)
		v2ray_host=$(echo "$decode_link" | jq -r .host)
	else
		# "old format"
		case $v2ray_net in
		tcp)
			v2ray_host=$(echo "$decode_link" | jq -r .host)
			v2ray_path=""
			;;
		kcp)
			v2ray_host=""
			v2ray_path=""
			;;
		ws)
			v2ray_host_tmp=$(echo "$decode_link" | jq -r .host)
			if [ -n "$v2ray_host_tmp" ]; then
				format_ws=$(echo $v2ray_host_tmp | grep -E ";")
				if [ -n "$format_ws" ]; then
					v2ray_host=$(echo $v2ray_host_tmp | cut -d ";" -f1)
					v2ray_path=$(echo $v2ray_host_tmp | cut -d ";" -f1)
				else
					v2ray_host=""
					v2ray_path=$v2ray_host
				fi
			fi
			;;
		h2)
			v2ray_host=""
			v2ray_path=$(echo "$decode_link" | jq -r .path)
			;;
		esac
	fi

	#把全部服务器节点编码后写入文件 /usr/share/shadowsocks/serverconfig/all_subscservers.txt
	[ -n "$v2ray_group" ] && group_base64=$(echo $v2ray_group | base64_encode | sed 's/ -//g')
	[ -n "$v2ray_add" ] && server_base64=$(echo $v2ray_add | base64_encode | sed 's/ -//g')
	[ -n "$v2ray_group" ] && [ -n "$v2ray_add" ] && echo $server_base64 $group_base64 >> /tmp/all_subscservers.txt

	# for debug
	# echo ------------------
	# echo v2ray_v: $v2ray_v
	# echo v2ray_ps: $v2ray_ps
	# echo v2ray_add: $v2ray_add
	# echo v2ray_port: $v2ray_port
	# echo v2ray_id: $v2ray_id
	# echo v2ray_net: $v2ray_net
	# echo v2ray_type: $v2ray_type
	# echo v2ray_host: $v2ray_host
	# echo v2ray_path: $v2ray_path
	# echo v2ray_tls: $v2ray_tls
	# echo ------------------
	
	[ -z "$v2ray_ps" -o -z "$v2ray_add" -o -z "$v2ray_port" -o -z "$v2ray_id" -o -z "$v2ray_aid" -o -z "$v2ray_net" -o -z "$v2ray_type" ] && return 1 || return 0
}

add_v2ray_servers(){
	let NODE_INDEX+=1
	[ -z "$1" ] && dbus set ssconf_basic_group_$NODE_INDEX=$v2ray_group
	dbus set ssconf_basic_type_$NODE_INDEX=2
	dbus set ssconf_basic_v2ray_mux_enable_$NODE_INDEX=0
	dbus set ssconf_basic_v2ray_use_json_$NODE_INDEX=0
	dbus set ssconf_basic_v2ray_security_$NODE_INDEX="auto"
	dbus set ssconf_basic_mode_$NODE_INDEX=$ssr_subscribe_mode
	dbus set ssconf_basic_name_$NODE_INDEX=$v2ray_ps
	dbus set ssconf_basic_port_$NODE_INDEX=$v2ray_port
	dbus set ssconf_basic_server_$NODE_INDEX=$v2ray_add
	dbus set ssconf_basic_v2ray_uuid_$NODE_INDEX=$v2ray_id
	dbus set ssconf_basic_v2ray_alterid_$NODE_INDEX=$v2ray_aid
	dbus set ssconf_basic_v2ray_network_security_$NODE_INDEX=$v2ray_tls
	dbus set ssconf_basic_v2ray_network_$NODE_INDEX=$v2ray_net
	dbus set ssconf_basic_v2ray_vmessvless_$NODE_INDEX="vmess"
	dbus set ssconf_basic_v2ray_fingerprint_$NODE_INDEX="disable"
	case $v2ray_net in
	tcp)
		# tcp协议设置【 tcp伪装类型 (type)】和【伪装域名 (host)】
		dbus set ssconf_basic_v2ray_headtype_tcp_$NODE_INDEX=$v2ray_type
		[ -n "$v2ray_host" ] && dbus set ssconf_basic_v2ray_network_host_$NODE_INDEX=$v2ray_host
		;;
	kcp)
		# kcp协议设置【 kcp伪装类型 (type)】
		dbus set ssconf_basic_v2ray_headtype_kcp_$NODE_INDEX=$v2ray_type
		;;
	ws|h2)
		# ws/h2协议设置【 伪装域名 (host))】和【路径 (path)】
		[ -n "$v2ray_host" ] && dbus set ssconf_basic_v2ray_network_host_$NODE_INDEX=$v2ray_host
		[ -n "$v2ray_path" ] && dbus set ssconf_basic_v2ray_network_path_$NODE_INDEX=$v2ray_path
		;;
	esac
	echo_date "v2ray节点：新增加【$v2ray_ps】到节点列表第 $NODE_INDEX 位。"
}

update_v2ray_config(){
	isadded_server=$(cat /tmp/all_localservers.txt | grep -w $group_base64 | awk '{print $1}' | grep -c $server_base64 | head -n1)
	if [ "$isadded_server" == "0" ]; then
		add_v2ray_servers
		let addnum+=1
	else
		# 如果在本地的订阅节点中已经有该节点（用group和server去判断），检测下配置是否更改，如果更改，则更新配置
		index=$(cat /tmp/all_localservers.txt | grep $group_base64 | grep $server_base64 | awk '{print $4}'|head -n1)
		local i=0
		dbus set ssconf_basic_mode_$index="$ssr_subscribe_mode"
		local local_v2ray_ps=$(eval echo \$ssconf_basic_name_$index)
		local local_v2ray_add=$(eval echo \$ssconf_basic_server_$index)
		local local_v2ray_port=$(eval echo \$ssconf_basic_port_$index)
		local local_v2ray_id=$(eval echo \$ssconf_basic_v2ray_uuid_$index)
		local local_v2ray_aid=$(eval echo \$ssconf_basic_v2ray_alterid_$index)
		local local_v2ray_tls=$(eval echo \$ssconf_basic_v2ray_network_security_$index)
		local local_v2ray_net=$(eval echo \$ssconf_basic_v2ray_network_$index)
		[ "$local_v2ray_ps" != "$v2ray_ps" ] && dbus set ssconf_basic_name_$index=$v2ray_ps && let i+=1
		[ "$local_v2ray_add" != "$v2ray_add" ] && dbus set ssconf_basic_server_$index=$v2ray_add && let i+=1
		[ "$local_v2ray_port" != "$v2ray_port" ] && dbus set ssconf_basic_port_$index=$v2ray_port && let i+=1
		[ "$local_v2ray_id" != "$v2ray_id" ] && dbus set ssconf_basic_v2ray_uuid_$index=$v2ray_id && let i+=1
		[ "$local_v2ray_aid" != "$v2ray_aid" ] && dbus set ssconf_basic_v2ray_alterid_$index=$v2ray_aid && let i+=1
		[ "$local_v2ray_tls" != "$v2ray_tls" ] && dbus set ssconf_basic_v2ray_network_security_$index=$v2ray_tls && let i+=1
		[ "$local_v2ray_net" != "$v2ray_net" ] && dbus set ssconf_basic_v2ray_network_$index=$v2ray_net && let i+=1
		case $local_v2ray_net in
		tcp)
			# tcp协议
			local local_v2ray_type=$(eval echo \$ssconf_basic_v2ray_headtype_tcp_$index)
			local local_v2ray_host=$(eval echo \$ssconf_basic_v2ray_network_host_$index)
			[ "$local_v2ray_type" != "$v2ray_type" ] && dbus set ssconf_basic_v2ray_headtype_tcp_$index=$v2ray_type && let i+=1
			[ "$local_v2ray_host" != "$v2ray_host" ] && dbus set ssconf_basic_v2ray_network_host_$index=$v2ray_host && let i+=1
			;;
		kcp)
			# kcp协议
			local local_v2ray_type=$(eval echo \$ssconf_basic_v2ray_headtype_kcp_$index)
			[ "$local_v2ray_type" != "$v2ray_type" ] && dbus set ssconf_basic_v2ray_headtype_kcp_$index=$v2ray_type && let i+=1
			;;
		ws|h2)
			# ws/h2协议
			local local_v2ray_host=$(eval echo \$ssconf_basic_v2ray_network_host_$index)
			local local_v2ray_path=$(eval echo \$ssconf_basic_v2ray_network_path_$index)
			[ "$local_v2ray_host" != "$v2ray_host" ] && dbus set ssconf_basic_v2ray_network_host_$index=$v2ray_host && let i+=1
			[ "$local_v2ray_path" != "$v2ray_path" ] && dbus set ssconf_basic_v2ray_network_path_$index=$v2ray_path && let i+=1
			;;
		esac
		dbus set ssconf_basic_v2ray_vmessvless_$index="vmess"
		dbus set ssconf_basic_v2ray_fingerprint_$index="disable"
		if [ "$i" -gt "0" ]; then
			echo_date "修改v2ray节点：【$v2ray_ps】" && let updatenum+=1
		else
			echo_date "v2ray节点：【$v2ray_ps】参数未发生变化，跳过！"
		fi
	fi
}

get_ssr_node_info(){
	decode_link="$1"
	action="$2"
	server=$(echo "$decode_link" | awk -F':' '{print $1}' | sed 's/[[:space:]]//g')
	server_port=$(echo "$decode_link" | awk -F':' '{print $2}')
	protocol=$(echo "$decode_link" | awk -F':' '{print $3}')
	encrypt_method=$(echo "$decode_link" |awk -F':' '{print $4}')
	obfs=$(echo "$decode_link" | awk -F':' '{print $5}' | sed 's/_compatible//g')
	password=$(decode_url_link $(echo "$decode_link" | awk -F':' '{print $6}' | awk -F'/' '{print $1}'))
	password=$(echo $password | base64_encode | sed 's/[[:space:]]//g')
	
	obfsparam_temp=$(echo "$decode_link" | awk -F':' '{print $6}' | grep -Eo "obfsparam.+" | sed 's/obfsparam=//g' | awk -F'&' '{print $1}')
	[ -n "$obfsparam_temp" ] && obfsparam=$(decode_url_link $obfsparam_temp) || obfsparam=''
	
	protoparam_temp=$(echo "$decode_link" | awk -F':' '{print $6}' | grep -Eo "protoparam.+" | sed 's/protoparam=//g' | awk -F'&' '{print $1}')
	[ -n "$protoparam_temp" ] && protoparam=$(decode_url_link $protoparam_temp | sed 's/_compatible//g') || protoparam=''
	
	remarks_temp=$(echo "$decode_link" | awk -F':' '{print $6}' | grep -Eo "remarks.+" | sed 's/remarks=//g' | awk -F'&' '{print $1}')
	if [ "$action" == "1" ]; then
		[ -n "$remarks_temp" ] && remarks=$(decode_url_link $remarks_temp) || remarks=""
	elif [ "$action" == "2" ]; then
		[ -n "$remarks_temp" ] && remarks=$(decode_url_link $remarks_temp) || remarks='AutoSuB'
	fi
	
	group_temp=$(echo "$decode_link" | awk -F':' '{print $6}' | grep -Eo "group.+" | sed 's/group=//g' | awk -F'&' '{print $1}')
	if [ "$action" == "1" ]; then
		[ -n "$group_temp" ] && group=$(decode_url_link $group_temp) || group=""
	elif [ "$action" == "2" ]; then
		[ -n "$group_temp" ] && group=$(decode_url_link $group_temp) || group='AutoSuBGroup'
	fi

	[ -n "$group" ] && group_base64=$(echo $group | base64_encode | sed 's/ -//g')
	[ -n "$server" ] && server_base64=$(echo $server | base64_encode | sed 's/ -//g')
	[ -n "$remarks" ] && remark_base64=$(echo $remarks | base64_encode | sed 's/ -//g')
 
	if [ -n "$group" -a -n "$server" -a -n "$server_port" -a -n "$password" -a -n "$protocol" -a -n "$obfs" -a -n "$encrypt_method" ]; then
		group_base64=$(echo $group | base64_encode | sed 's/ -//g')
		server_base64=$(echo $server | base64_encode | sed 's/ -//g')	
		remark_base64=$(echo $remarks | base64_encode | sed 's/ -//g')
		echo $server_base64 $group_base64 $remark_base64 >> /tmp/all_subscservers.txt
		echo "$group" >> /tmp/all_group_info.txt
	else
		return 1
	fi
	
	# for debug, please keep it here~
	# echo ------------
	# echo group: $group
	# echo remarks: $remarks
	# echo server: $server
	# echo server_port: $server_port
	# echo password: $password
	# echo encrypt_method: $encrypt_method
	# echo protocol: $protocol
	# echo protoparam: $protoparam
	# echo obfs: $obfs
	# echo obfsparam: $obfsparam
	# echo ------------
}

update_ssr_nodes(){
	local FAILED_FLAG=$1
	local UPDATE_FLAG
	local DELETE_FLAG
	local SKIPDB_FLAG
	local INFO

	if [ "$FAILED_FLAG" == "1" ]; then
		echo_date "检测到一个错误节点，跳过！"
		return 1
	fi
	
	# ------------------------------- 关键词匹配逻辑 -------------------------------
	# 用[排除]和[包括]关键词去匹配，剔除掉用户不需要的节点，剩下的需要的节点：UPDATE_FLAG=0，
	# UPDATE_FLAG=0,需要的节点；1.判断本地是否有此节点，2.如果有就添加，没有就判断是否需要更新
	# UPDATE_FLAG=2,不需要的节点；1. 判断本地是否有此节点，2.如果有就删除，没有就不管
	
	[ -n "$KEY_WORDS_1" ] && local KEY_MATCH_1=$(echo $remarks $server | grep -Eo "$KEY_WORDS_1")
	[ -n "$KEY_WORDS_2" ] && local KEY_MATCH_2=$(echo $remarks $server | grep -Eo "$KEY_WORDS_2")
	if [ -n "$KEY_WORDS_1" -a -z "$KEY_WORDS_2" ]; then
		if [ -n "$KEY_MATCH_1" ]; then
			echo_date "SSR节点：不添加【$remarks】节点，因为匹配了[排除]关键词"
			let exclude+=1 
			local UPDATE_FLAG=2
		else
			local UPDATE_FLAG=0
		fi
	elif [ -z "$KEY_WORDS_1" -a -n "$KEY_WORDS_2" ]; then
		if [ -z "$KEY_MATCH_2" ]; then
			echo_date "SSR节点：不添加【$remarks】节点，因为不匹配[包括]关键词"
			let exclude+=1 
			local UPDATE_FLAG=2
		else
			local UPDATE_FLAG=0
		fi
	elif [ -n "$KEY_WORDS_1" -a -n "$KEY_WORDS_2" ]; then
		if [ -n "$KEY_MATCH_1" -a -z "$KEY_MATCH_2" ]; then
			echo_date "SSR节点：不添加【$remarks】节点，因为匹配了[排除+包括]关键词"
			let exclude+=1 
			local UPDATE_FLAG=2
		elif [ -n "$KEY_MATCH_1" -a -n "$KEY_MATCH_2" ]; then
			echo_date "SSR节点：不添加【$remarks】节点，因为匹配了[排除]关键词"
			let exclude+=1 
			local UPDATE_FLAG=2
		elif  [ -z "$KEY_MATCH_1" -a -z "$KEY_MATCH_2" ]; then
			echo_date "SSR节点：不添加【$remarks】节点，因为不匹配[包括]关键词"
			let exclude+=1 
			local UPDATE_FLAG=2
		else
			local UPDATE_FLAG=0
		fi
	else
		local UPDATE_FLAG=0
	fi
	
	# ------------------------------- 节点添加/修改逻辑 -------------------------------
	local isadded_server=$(cat /tmp/all_localservers.txt | grep $group_base64 | awk '{print $1}' | grep -wc $server_base64 | head -n1)
	local isadded_remark=$(cat /tmp/all_localservers.txt | grep $group_base64 | awk '{print $3}' | grep -wc $remark_base64 | head -n1)
	if [ "$isadded_server" == "0" -a "$isadded_remark" == "0" ]; then
		#地址匹配：no，名称匹配：no；说明是本地没有的新节点，添加它！
		if [ "$UPDATE_FLAG" == "0" ]; then
			# usleep 100000
			let NODE_INDEX+=1
			echo_date "SSR节点：新增加【$remarks】到节点列表第 $NODE_INDEX 位。"
			dbus set ssconf_basic_name_$NODE_INDEX=$remarks
			dbus set ssconf_basic_group_$NODE_INDEX=$group
			dbus set ssconf_basic_mode_$NODE_INDEX=$ssr_subscribe_mode
			dbus set ssconf_basic_server_$NODE_INDEX=$server
			dbus set ssconf_basic_port_$NODE_INDEX=$server_port
			dbus set ssconf_basic_ssr_protocol_$NODE_INDEX=$protocol
			dbus set ssconf_basic_method_$NODE_INDEX=$encrypt_method
			dbus set ssconf_basic_ssr_obfs_$NODE_INDEX=$obfs
			dbus set ssconf_basic_type_$NODE_INDEX="1"
			dbus set ssconf_basic_password_$NODE_INDEX=$password
			[ -n "$protoparam" ] && dbus set ssconf_basic_ssr_protocol_param_$NODE_INDEX=$protoparam
			[ "$ssr_subscribe_obfspara" == "0" ] && dbus remove ssconf_basic_ssr_obfs_param_$NODE_INDEX
			[ "$ssr_subscribe_obfspara" == "1" ] && [ -n "$obfsparam" ] && dbus set ssconf_basic_ssr_obfs_param_$NODE_INDEX="$obfsparam"
			[ "$ssr_subscribe_obfspara" == "2" ] && dbus set ssconf_basic_ssr_obfs_param_$NODE_INDEX="$ssr_subscribe_obfspara_val"
			let addnum+=1
		fi
	elif [ "$isadded_server" == "0" -a "$isadded_remark" != "0" ]; then
		#地址匹配：no，名称匹配：yes；说明可能是机场更改了节点域名地址，通过节点名称获取index
		local index_line_remark=$(cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $remark_base64 | awk '{print $4}' | wc -l)
		if [ "$index_line_remark" == "1" ]; then
			local index=$(cat /tmp/all_localservers.txt| grep $group_base64 | grep -w $remark_base64 | awk '{print $4}')
		else
			# 如果有些机场有名称重复的节点（垃圾机场！），把同名节点序号写进文件-1后依次去取节点号
			local tmp_file=$(echo $remark_base64 | sed 's/\=//g')
			if [ ! -f /tmp/multi_remark_${tmp_file}.txt -o $(cat /tmp/multi_remark_${tmp_file}.txt | wc -l) == "0" ]; then
				# 节点名称的base64值，去掉"="后，作为文件名写入/tmp，后面遇到该节点（节点名称相同的节点）就能从里面取值啦
				cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $remark_base64 | awk '{print $4}' > /tmp/multi_remark_${tmp_file}.txt
			fi
			local index=$(cat /tmp/multi_remark_${tmp_file}.txt | sed -n '1p')
			sed -i '1d' /tmp/multi_remark_${tmp_file}.txt
		fi
		# add SKIPDB_FLAG
		local SKIPDB_FLAG=1
	else
		# 地址匹配：yes，名称匹配：yes/no；说明可能是机场更改了节点名字或其它参数，通过节点名称获取index
		local index_line_server=$(cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $server_base64 | awk '{print $4}' | wc -l)
		if [ "$index_line_server" == "1" ]; then
			local index=$(cat /tmp/all_localservers.txt| grep $group_base64 | grep -w $server_base64 | awk '{print $4}')
		else
			# 如果有些机场有域名重复的节点，如一些用于流量提示和过期日期提醒的假节点，把同名节点序号写进文件-2后依次去取节点号
			local tmp_file=$(echo $server_base64 | sed 's/\=//g')
			if [ ! -f /tmp/multi_server_${tmp_file}.txt -o $(cat /tmp/multi_server_${tmp_file}.txt | wc -l) == "0" ]; then
				# 节点的base64值，去掉"="后，作为文件名写入/tmp，后面遇到该节点（server值相同的节点）就能从里面取值啦
				cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $server_base64 | awk '{print $4}' > /tmp/multi_server_${tmp_file}.txt
			fi
			local index=$(cat /tmp/multi_server_${tmp_file}.txt | sed -n '1p')
			sed -i '1d' /tmp/multi_server_${tmp_file}.txt
		fi
		# add SKIPDB_FLAG
		local SKIPDB_FLAG=2
	fi

	# SKIPDB_FLAG不为空，说明本地找到对应节点，且拿到了节点的index
	if [ "$SKIPDB_FLAG" == "1" -o "$SKIPDB_FLAG" == "2" ]; then
		# 在本地的节点中找到该节点，但是该节点被用户定义定义的关键词过滤了，那么删除它
		local KEY_LOCAL_NAME=$(cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $index | awk '{print $3}' | base64 -d)
		local KEY_LOCAL_SERVER=$(cat /tmp/all_localservers.txt | grep $group_base64 | grep -w $index | awk '{print $1}'| base64 -d)

		[ -n "$KEY_WORDS_1" ] && local KEY_MATCH_3=$(echo $KEY_LOCAL_NAME $KEY_LOCAL_SERVER | grep -Eo "$KEY_WORDS_1")
		[ -n "$KEY_WORDS_2" ] && local KEY_MATCH_4=$(echo $KEY_LOCAL_NAME $KEY_LOCAL_SERVER | grep -Eo "$KEY_WORDS_2")

		if [ -n "$KEY_WORDS_1" -a -z "$KEY_WORDS_2" ]; then
			if [ -n "$KEY_MATCH_3" ]; then
				echo_date "SSR节点：移除本地【$remarks】节点，因为匹配了[排除]关键词"
				local DELETE_FLAG=1
			else
				local DELETE_FLAG=0
			fi
		elif [ -z "$KEY_WORDS_1" -a -n "$KEY_WORDS_2" ]; then
			if [ -z "$KEY_MATCH_4" ]; then
				echo_date "SSR节点：移除本地【$remarks】节点，因为不匹配[包括]关键词"
				local DELETE_FLAG=1
			else
				local DELETE_FLAG=0
			fi
		elif [ -n "$KEY_WORDS_1" -a -n "$KEY_WORDS_2" ]; then
			if [ -n "$KEY_MATCH_3" -a -z "$KEY_MATCH_4" ]; then
				echo_date "SSR节点：移除本地【$remarks】节点，因为匹配了[排除+包括]关键词"
				local DELETE_FLAG=1
			elif [ -n "$KEY_MATCH_3" -a -n "$KEY_MATCH_4" ]; then
				echo_date "SSR节点：移除本地【$remarks】节点，因为匹配了[排除]关键词"
				local DELETE_FLAG=1
			elif  [ -z "$KEY_MATCH_3" -a -z "$KEY_MATCH_4" ]; then
				echo_date "SSR节点：移除本地【$remarks】节点，因为不匹配[包括]关键词"
				local DELETE_FLAG=1
			else
				local DELETE_FLAG=0
			fi
		else
			local DELETE_FLAG=0
		fi

		if [ "$DELETE_FLAG" == "1" ]; then
			# 删除此节点
			for item in $PREFIX
			do
				if [ -n "$(eval echo \$${item}${index})" ]; then
					 dbus remove ${item}${index}
				fi
			done
			let delnum+=1
		else
			# 在本地的订阅节点中找到该节点，检测下配置是否更改，如果更改，则更新配置
			local local_mode="$(eval echo \$ssconf_basic_mode_$index)"
			local local_remark="$(eval echo \$ssconf_basic_name_$index)"
			local local_server="$(eval echo \$ssconf_basic_server_$index)"
			local local_server_port="$(eval echo \$ssconf_basic_port_$index)"
			local local_password="$(eval echo \$ssconf_basic_password_$index)"
			local local_encrypt_method="$(eval echo \$ssconf_basic_method_$index)"
			local local_protocol="$(eval echo \$ssconf_basic_ssr_protocol_$index)"
			local local_protocol_param="$(eval echo \$ssconf_basic_ssr_protocol_param_$index)"
			local local_obfs="$(eval echo \$ssconf_basic_ssr_obfs_$index)"
			local local_obfsparam="$(eval echo \$ssconf_basic_ssr_obfs_param_$index)"
			
			[ "$local_mode" != "$ssr_subscribe_mode" ] && dbus set ssconf_basic_mode_$index="$ssr_subscribe_mode" && INFO="${INFO}模式"
			[ "$SKIPDB_FLAG" == "2" ] && [ "$local_remark" != "$remarks" ] && dbus set ssconf_basic_name_$index="$remarks" && INFO="${INFO}名称 "
			[ "$SKIPDB_FLAG" == "1" ] && [ "$local_server" != "$server" ] && dbus set ssconf_basic_server_$index="$server" && INFO="${INFO}服务器地址 "
			[ "$local_server_port" != "$server_port" ] && dbus set ssconf_basic_port_$index="$server_port" && INFO="${INFO}端口 "
			[ "$local_password" != "$password" ] && dbus set ssconf_basic_password_$index="$password" && INFO="${INFO}密码 "
			[ "$local_encrypt_method" != "$encrypt_method" ] && dbus set ssconf_basic_method_$index="$encrypt_method" && INFO="${INFO}加密 "
			[ "$local_protocol" != "$protocol" ] && dbus set ssconf_basic_ssr_protocol_$index="$protocol" && INFO="${INFO}协议 "
			[ "$local_protocol_param" != "$protoparam" ] && dbus set ssconf_basic_ssr_protocol_param_$index="$protoparam" && INFO="${INFO}协议参数 "
			if [ -z "$protoparam" ]; then
				[ -n "$local_protocol_param" ] && dbus remove ssconf_basic_ssr_protocol_param_$index && INFO="${INFO}协议参数 "
			else
				[ "$local_protocol_param" != "$protoparam" ] && dbus set ssconf_basic_ssr_protocol_param_$index="$protoparam" && INFO="${INFO}协议参数 "
			fi
			[ "$local_obfs" != "$obfs" ] && dbus set ssconf_basic_ssr_obfs_$index="$obfs" && INFO="${INFO}混淆 "
			[ "$ssr_subscribe_obfspara" == "0" ] && [ -n "$local_obfsparam" ] dbus remove ssconf_basic_ssr_obfs_param_$index && INFO="${INFO}混淆参数 "
			[ "$ssr_subscribe_obfspara" == "1" ] && {
				if [ -z "$obfsparam" ]; then
					[ -n "$local_obfsparam" ] && dbus remove ssconf_basic_ssr_obfs_param_$index && INFO="${INFO}混淆参数 "
				else
					[ "$local_obfsparam" != "$obfsparam" ] && dbus set ssconf_basic_ssr_obfs_param_$index="$obfsparam" && INFO="${INFO}混淆参数 "
				fi
			}
			[ "$ssr_subscribe_obfspara" == "2" ] && [ "$local_obfsparam" != "$ssr_subscribe_obfspara_val" ] && dbus set ssconf_basic_ssr_obfs_param_$index="$ssr_subscribe_obfspara_val" && INFO="${INFO}混淆参数 "
			
			if [ -n "$INFO" ]; then
				INFO=$(trim_string "$INFO")
				echo_date "SSR节点：更新【$remarks】，原因：节点的【${INFO}】发生了更改！"
				let updatenum+=1
			else
				echo_date "SSR节点：【$remarks】 参数未发生变化，跳过！"
			fi
		fi
	fi

	# 添加/更改完成一个节点后，将该节点的group信息写入到文件备用
	echo $group >> /tmp/sub_group_info.txt
}

del_none_exist(){
	# 通过本地节点和订阅节点对比，找出本地独有的节点[域名]对应的节点索引
	local DIFF_SERVERS=$(awk 'NR==FNR{a[$1]=$1} NR>FNR{if(a[$1] == ""){print $4}}' /tmp/all_subscservers.txt /tmp/all_localservers.txt | sed '/^$/d')
	# 通过本地节点和订阅节点对比，找出本地独有的节点[名称]对应的节点索引
	local DIFF_REMARKS=$(awk 'NR==FNR{a[$3]=$3} NR>FNR{if(a[$3] == ""){print $4}}' /tmp/all_subscservers.txt /tmp/all_localservers.txt | sed '/^$/d')
	# 获取两者都有的节点索引，即为需要删除的节点
	local DEL_INDEXS=$(echo $DIFF_SERVERS $DIFF_REMARKS | sed 's/[[:space:]]/\n/g' | sort | uniq -d)
	# 删除操作
	[ -n "$DEL_INDEXS" ] && echo_date "==================================================================="
	for DEL_INDEX in $DEL_INDEXS; do
		echo_date "SSR节点：删除【$(eval echo \$ssconf_basic_name_$DEL_INDEX)】，因为该节点在订阅服务器上已经不存在..."
		for item in $PREFIX; do
			if [ -n "$(eval echo \$${item}${DEL_INDEX})" ]; then
				dbus remove ${item}${DEL_INDEX}
			fi
		done
		let delnum+=1
	done
}

remove_node_gap(){
	# 虽然web上已经可以自动化无缝重排序了，但是考虑到有的用户设置了插件自动化，长期不进入web，而后台更新节点持续一段时间后，节点顺序还是会很乱，所以保留此功能
	SEQ=$(export -p | grep "ssconf_basic" | grep _name_ | cut -d "_" -f 4 | cut -d "=" -f 1 | sort -n)
	MAX=$(export -p | grep "ssconf_basic" | grep _name_ | cut -d "_" -f 4 | cut -d "=" -f 1 | sort -rn | head -n1)
	NODES_NU=$(export -p | grep "ssconf_basic" | grep _name_ | wc -l)
	
	echo_date "最大节点序号：$MAX"
	echo_date "共有节点数量：$NODES_NU"
	if [ "$MAX" != "$NODES_NU" ]; then
		echo_date "节点排序需要调整!"
		local y=1
		for nu in $SEQ
		do
			if [ "$y" == "$nu" ]; then
				echo_date "节点$y不需要调整！"
			else
				echo_date "调整节点$nu到节点$y！"
				for item in $PREFIX
				do
					#dbus remove ${item}${conf_nu}
					if [ -n "$(eval echo \$${item}${nu})" ]; then
						dbus set ${item}${y}="$(eval echo \$${item}${nu})"
						dbus remove ${item}${nu}
					fi
				done
				if [ "$nu" == "$ssconf_basic_node" ]; then
					dbus set ssconf_basic_node=${y}
				fi
				if [ -n "$ss_basic_udp_node" -a "$nu" == "$ss_basic_udp_node" ]; then
					dbus set ss_basic_udp_node=${y}
				fi				
			fi
			let y+=1
		done
	else
		echo_date "节点排序正确!"
	fi
}

gap_test(){
	unset ssconf_basic_name_8
	unset ssconf_basic_name_9
	unset ssconf_basic_name_11
	unset ssconf_basic_name_12
	unset ssconf_basic_name_33
	unset ssconf_basic_name_44
	unset ssconf_basic_name_47
	unset ssconf_basic_name_52
	
	SEQ=$(export -p | grep "ssconf_basic" | grep _name_ | cut -d "_" -f 4 | cut -d "=" -f 1 | sort -n)
	SEQ_SUB=$(export -p | grep "ssconf_basic" | grep _group_ | cut -d "_" -f 4 | cut -d "=" -f 1 | sort -n)
	MAX=$(export -p | grep "ssconf_basic" | grep _name_ | cut -d "_" -f 4 | cut -d "=" -f 1 | sort -rn | head -n1)
	NODES_NU=$(export -p | grep "ssconf_basic" | grep _name_ | wc -l)

	echo_date "节点排序情况：$SEQ"
	echo_date "订阅排序情况：$SEQ_SUB"
	echo_date "最大节点序号：$MAX"
	echo_date "共有节点数量：$NODES_NU"
	echo_date "共有间隔数量：$(($MAX - $NODES_NU))"
	echo_date "需要移除节点：$(($NODES_NU + 1)) - $MAX"

	local nu=$(($NODES_NU + 1))
	while [ "$nu" -le "$MAX" ]; do
		for item in $PREFIX
		do
			if [ -n "$(eval echo \$${item}${nu})" ]; then
				dbus remove ${item}${nu}
			fi
		done
		let nu+=1
	done
}

open_socks_23456(){
	socksopen_a=$(netstat -nlp | grep -w 23456 | grep -E "local|v2ray")
	if [ -z "$socksopen_a" ]; then
		if [ "$ss_basic_type" == "1" ]; then
			SOCKS_FLAG=1
			echo_date "开启ssr-local，提供socks5代理端口：23456"
			ssr-local -l 23456 -c $CONFIG_FILE -u -f /var/run/sslocal1.pid >/dev/null 2>&1
		elif  [ "$ss_basic_type" == "0" ]; then
			SOCKS_FLAG=2
			echo_date "开启ss-local，提供socks5代理端口：23456"
			if [ "$ss_basic_ss_obfs" == "0" ] && [ "$ss_basic_ss_v2ray" == "0" ]; then
				ss-local -l 23456 -c $CONFIG_FILE -u -f /var/run/sslocal1.pid >/dev/null 2>&1
			else
				ss-local -l 23456 -c $CONFIG_FILE $ARG_OBFS -u -f /var/run/sslocal1.pid >/dev/null 2>&1
			fi
		fi
	fi
	sleep 2
}

get_oneline_rule_now(){
	# ss订阅
	ssr_subscribe_link="$1"
	LINK_FORMAT=$(echo "$ssr_subscribe_link" | grep -E "^http://|^https://")
	[ -z "$LINK_FORMAT" ] && return 4
	
	echo_date "开始更新在线订阅列表..." 
	echo_date "开始下载订阅链接到本地临时文件，请稍等..."
	rm -rf /tmp/ssr_subscribe_file* >/dev/null 2>&1
	
	if [ "$ss_basic_online_links_goss" == "1" ]; then
		open_socks_23456
		socksopen_b=$(netstat -nlp | grep -w 23456 | grep -E "local|v2ray|trojan")
		if [ -n "$socksopen_b" ]; then
			echo_date "使用$(get_type_name $ss_basic_type)提供的socks代理网络下载..."
			curl -4sSk --connect-timeout 8 --socks5-hostname 127.0.0.1:23456 $ssr_subscribe_link > /tmp/ssr_subscribe_file.txt
		else
			echo_date "没有可用的socks5代理端口，改用常规网络下载..."
			curl -4sSk --connect-timeout 8 $ssr_subscribe_link > /tmp/ssr_subscribe_file.txt
		fi
	else
		echo_date "使用常规网络下载..."
		curl -4sSk --connect-timeout 8 $ssr_subscribe_link > /tmp/ssr_subscribe_file.txt
	fi

	#虽然为0但是还是要检测下是否下载到正确的内容
	if [ "$?" == "0" ]; then
		#下载为空...
		if [ -z "$(cat /tmp/ssr_subscribe_file.txt)" ]; then
			#echo_date "下载内容为空..."
			echo_date "使用curl下载成功，但是内容为空，尝试更换wget进行下载..."
			rm /tmp/ssr_subscribe_file.txt
			if [ -n $(echo $ssr_subscribe_link | grep -E "^https") ]; then
				wget --no-check-certificate --timeout=15 -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
			else
				wget -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
			fi
			#return 3
			sleep 1s
		else
			#订阅地址有跳转
			local blank=$(cat /tmp/ssr_subscribe_file.txt | grep -E " |Redirecting|301")
			if [ -n "$blank" -o -z "$(cat /tmp/ssr_subscribe_file.txt)" ]; then
				echo_date "订阅链接可能有跳转，尝试更换wget进行下载..."
				rm /tmp/ssr_subscribe_file.txt
				if [ -n $(echo $ssr_subscribe_link | grep -E "^https") ]; then
					wget --no-check-certificate --timeout=15 -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
				else
					wget -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
				fi
			fi
		fi
		if [ -z "$(cat /tmp/ssr_subscribe_file.txt)" ]; then
			echo_date "wget下载内容为空..."
			return 3
		fi
		#产品信息错误
		local wrong1=$(cat /tmp/ssr_subscribe_file.txt | grep "{")
		local wrong2=$(cat /tmp/ssr_subscribe_file.txt | grep "<")
		if [ -n "$wrong1" -o -n "$wrong2" ]; then
			return 2
		fi
	else
		echo_date "使用curl下载订阅失败，尝试更换wget进行下载..."
		rm /tmp/ssr_subscribe_file.txt
		if [ -n $(echo $ssr_subscribe_link | grep -E "^https") ]; then
			wget --no-check-certificate --timeout=15 -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
		else
			wget -qO /tmp/ssr_subscribe_file.txt $ssr_subscribe_link
		fi

		if [ "$?" == "0" ]; then
			#下载为空...
			if [ -z "$(cat /tmp/ssr_subscribe_file.txt)" ]; then
				echo_date "下载内容为空..."
				return 3
			fi
			#产品信息错误
			local wrong1=$(cat /tmp/ssr_subscribe_file.txt | grep "{")
			local wrong2=$(cat /tmp/ssr_subscribe_file.txt | grep "<")
			if [ -n "$wrong1" -o -n "$wrong2" ]; then
				return 2
			fi
		else
			return 1
		fi
	fi

	if [ "$?" == "0" ]; then
		# 删除上一个订阅的group信息
		rm -rf /tmp/sub_group_info.txt
		echo_date "下载订阅成功..."
		echo_date "开始解析节点信息..."
		decode_url_link $(cat /tmp/ssr_subscribe_file.txt) > /tmp/ssr_subscribe_file_temp1.txt
		# 检测 ss ssr vmess
		NODE_FORMAT1=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -E "^ss://")
		NODE_FORMAT2=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -E "^ssr://")
		NODE_FORMAT3=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -E "^vmess://")
		NODE_FORMAT4=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -E "^trojan://")
		if [ -n "$NODE_FORMAT1" ]; then
			# 每次更新后进行初始化
			urllinks=""
			link=""
			decode_link=""
			group=""
			group=$(echo $ssr_subscribe_link|awk -F'[/:]' '{print $4}')
			# 储存对应订阅链接的group信息
			dbus set ss_online_group_$z=$group
			echo $group >> /tmp/group_info.txt	
			NODE_NU0=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -c "^ss://")
			echo_date "检测到ss节点格式，共计$NODE_NU0个节点..."
			urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep -E "^ss://" | sed 's/ss:\/\///g')
			[ -z "$urllinks" ] && continue
			for link in $urllinks
			#对节点信息进行拆分			
			do
				if [ -n "$(echo -n "$link" | grep "#")" ];then
					#去掉ss://头部跟#后的标题
					new_sslink=$(echo -n "$link" | awk -F'#' '{print $1}' | sed 's/ss:\/\///g')		
					# 有些链接被 url 编码过，所以要先 url 解码
					link=$(printf $(echo -n $link | sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g'))
					new_sslink=$(printf $(echo -n $new_sslink | sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g'))
					#remarks=香港高级CN201
					remarks=$(echo -n "$link" | awk -F'#' '{print $2}' | sed 's/[\r\n ]//g')	
					
				else
					new_sslink=$(echo -n "$link" | sed 's/s:\/\///g')
					remarks='AddByLink'
				fi
				if [ -z "$(echo -n "$new_sslink" | grep "@")" ];then
					new_sslink="$(decode_url_link $(echo -n "$new_sslink"))"
				fi
				get_ss_config "$new_sslink" 
				[ "$?" == "0" ] && update_ss_config || echo_date "检测到一个错误ss节点，已经跳过！"
			done
			
			# 去除订阅服务器上已经删除的节点
			#del_none_exist
			# 节点重新排序
			#remove_node_gap
			USER_ADD0=$(($(export -p | grep ssconf_basic_ | grep _name_ | wc -l) - $(export -p | grep ssconf_basic_ | grep _group_ | wc -l))) || "0"
			ONLINE_GET0=$(dbus list ssconf_basic_ | grep _group_ | wc -l) || "0"

			echo_date "现共有自添加节点：$USER_ADD0 个；" >> $LOG_FILE

			echo_date "现共有订阅SS节点：$ONLINE_GET0 个；" >> $LOG_FILE
			echo_date "-------------------------------------------------------------------"
			#echo_date "在线订阅列表更新完成!"	
		fi
		if [ -n "$NODE_FORMAT2" ]; then
			# 每次更新后进行初始化
			urllinks=""
			link=""
			decode_link=""
			group=""
			# SSR 订阅
			#local NODE_NU=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -c "ssr://")
			NODE_NU1=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -c "ssr://")
			echo_date "检测到ssr节点格式，共计$NODE_NU1个节点..."
			# 判断格式
			maxnum=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep "MAX=" | awk -F"=" '{print $2}' | grep -Eo "[0-9]+")
			if [ -n "$maxnum" ]; then
				# 如果机场订阅解析后有MAX=xx字段存在，那么随机选取xx个节点，并去掉ssr://头部标识
				urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | sed '/MAX=/d' | shuf -n $maxnum | sed 's/ssr:\/\///g')
			else
				# 生成全部节点的节点信息，并去掉ssr://头部标识
				#urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | sed 's/ssr:\/\///g')
				urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep -E "^ssr://" | sed 's/ssr:\/\///g')
			fi
			[ -z "$urllinks" ] && continue
			# 针对每个节点进行解码：decode_link，解析：get_ssr_node_info，添加/修改：update_ssr_nodes
			for link in $urllinks
			do
				decode_link=$(decode_url_link $link)
				get_ssr_node_info $decode_link 1
				update_ssr_nodes $?
			done
			# 储存对应订阅链接的group信息
			group=$(cat /tmp/sub_group_info.txt | sort -u | sed 's/$/ + /g' | sed ':a;N;$!ba;s#\n##g' | sed 's/[[:space:]]+[[:space:]]$//g')
			if [ -n "$group" ]; then
				dbus set ss_online_group_$z=$group
				echo $group >> /tmp/group_info.txt
			else
				# 如果最后一个节点是空的，那么使用这种方式去获取group名字
				group=$(cat /tmp/all_group_info.txt | sort -u | tail -n1)
				[ -n "$group" ] && dbus set ss_online_group_$z=$group
				[ -n "$group" ] && echo $group >> /tmp/group_info.txt
			fi
			# INFO
			USER_ADD1=$(($(export -p | grep ssconf_basic_ | grep _name_ | wc -l) - $(export -p | grep ssconf_basic_ | grep _group_ | wc -l))) || "0"
			ONLINE_GET1_1=$(dbus list ssconf_basic_ | grep _group_ | wc -l) || "0"
			let ONLINE_GET1=ONLINE_GET1_1-ONLINE_GET0


			echo_date "现共有自添加节点：$USER_ADD1 个；" >> $LOG_FILE

			echo_date "现共有订阅SSR节点：$ONLINE_GET1 个；" >> $LOG_FILE
			echo_date "-------------------------------------------------------------------"
		fi
		
		if [ -n "$NODE_FORMAT3" ]; then
			# 每次更新后进行初始化
			urllinks=""
			link=""
			decode_link=""
			group=""
			# v2ray 订阅
			# use domain as group
			#v2ray_group_tmp=$(echo $ssr_subscribe_link | awk -F'[/:]' '{print $4}')
			group=$(echo $ssr_subscribe_link | awk -F'[/:]' '{print $4}')
			# 储存对应订阅链接的group信息
			dbus set ss_online_group_$z=$group
			echo $group >> /tmp/group_info.txt
			# detect format again
			if [ -n "$NODE_FORMAT1" ]; then
				#vmess://里夹杂着ss://
				NODE_NU2=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -Ec "vmess://|ss://")
				echo_date "检测到vmess和ss节点格式，共计$NODE_NU2个节点..."
				#urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | sed 's/ssr:\/\///g')
				urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep -E "^vmess://|ss://" | sed 's/vmess:\/\///g')
				for link in $urllinks
				do
					decode_link=$(decode_url_link $link)
					decode_link=$(echo $decode_link | jq -c .)
					if [ -n "$decode_link" ]; then
						get_v2ray_remote_config "$decode_link" "$group"
						[ "$?" == "0" ] && update_v2ray_config || echo_date "检测到一个错误节点，已经跳过！"
					else
						echo_date "解析失败！！！"
					fi
				done
			else
				# 纯vmess://
				NODE_NU2=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -Ec "vmess://")
				echo_date "检测到vmess节点格式，共计$NODE_NU2个节点..."
				echo_date "开始解析vmess节点格式"
				#urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | sed 's/vmess:\/\///g')
				urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep -E "^vmess://" | sed 's/vmess:\/\///g')
				for link in $urllinks
				do
					decode_link=$(decode_url_link $link)
					decode_link=$(echo $decode_link | jq -c .)
					if [ -n "$decode_link" ]; then
						get_v2ray_remote_config "$decode_link" "$group"
						[ "$?" == "0" ] && update_v2ray_config || echo_date "检测到一个错误节点，已经跳过！"
					else
						echo_date "解析失败！！！"
					fi
				done
			fi
			# INFO
			USER_ADD2=$(($(export -p | grep ssconf_basic_ | grep _name_ | wc -l) - $(export -p | grep ssconf_basic_ | grep _group_ | wc -l))) || "0"
			ONLINE_GET2_1=$(dbus list ssconf_basic_ | grep _group_ | wc -l) || "0"
			let ONLINE_GET2=ONLINE_GET2_1-ONLINE_GET1-ONLINE_GET0
			
			#echo_date "本次更新订阅来源 【$group】， 新增节点 $addnum 个，修改 $updatenum 个，删除 $delnum 个；"
			echo_date "现共有自添加节点：$USER_ADD2 个。"
			echo_date "现共有订阅v2ray节点：$ONLINE_GET2 个。"
			echo_date "-------------------------------------------------------------------"
			#echo_date "在线订阅列表更新完成!"	
		fi
		if [ -n "$NODE_FORMAT4" ];then
			# 每次更新后进行初始化
			urllinks=""
			link=""
			decode_link=""
			group=""
			# Trojan 订阅
			# use domain as group
			group=$(echo $ssr_subscribe_link|awk -F'[/:]' '{print $4}')
			# 储存对应订阅链接的group信息
			dbus set ss_online_group_$z=$group
			echo $group >> /tmp/group_info.txt
			# 统计trojan节点数量
			NODE_NU3=$(cat /tmp/ssr_subscribe_file_temp1.txt | grep -c "trojan://")
			echo_date "检测到 Trojan 节点格式，共计 $NODE_NU3 个节点..."
			#urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | sed 's/trojan:\/\///g')
			urllinks=$(decode_url_link $(cat /tmp/ssr_subscribe_file.txt) | grep -E "^trojan://" | sed 's/trojan:\/\///g')
			[ -z "$urllinks" ] && continue
			for link in $urllinks
			#对节点信息进行拆分
			
			do
				if [ -n "$(echo -n "$link" | grep "#")" ];then
					new_sslink=$(echo -n "$link" | awk -F'#' '{print $1}' | sed 's/trojan:\/\///g')		
					# 有些链接被 url 编码过，所以要先 url 解码
					link=$(printf $(echo -n $link | sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g'))
					# 因为订阅的 trojan 里面有 \r\n ，所以需要先去除，否则就炸了，只能卸载重装
					remarks=$(echo -n "$link" | awk -F'#' '{print $2}' | sed 's/[\r\n ]//g')	
					
				else
					new_sslink=$(echo -n "$link" | sed 's/trojan:\/\///g')
					remarks='AddByLink'
				fi
				# 链接中有 ? 开始的参数，去掉这些参数 20201024取消
				#new_trojan_link=$(echo -n "$new_sslink" | awk -F'?' '{print $1}')	
				#get_trojan_config $new_trojan_link
				get_trojan_config "$new_sslink"
				[ "$?" == "0" ] && update_trojan_config || echo_date "检测到一个错误节点，已经跳过！"
			done

			# 去除订阅服务器上已经删除的节点
			#del_none_exist
			# 节点重新排序
			#remove_node_gap
			USER_ADD3=$(($(dbus list ssconf_basic_|grep _name_|wc -l) - $(dbus list ssconf_basic_|grep _group_|wc -l))) || 0
			ONLINE_GET3_1=$(dbus list ssconf_basic_|grep _group_|wc -l) || 0

			let ONLINE_GET3=ONLINE_GET3_1-ONLINE_GET2-ONLINE_GET1-ONLINE_GET0
			#echo_date "本次更新订阅来源 【$group】， 新增节点 $addnum 个，修改 $updatenum 个，删除 $delnum 个；"
			echo_date "现共有自添加 节点：$USER_ADD3 个。"
			echo_date "现共有订阅 Trojan 节点：$ONLINE_GET3 个。"
			echo_date "-------------------------------------------------------------------"
			#echo_date "在线订阅列表更新完成!"		
		fi
	else
		return 1
	fi
	USER_ADD=$(($(dbus list ssconf_basic_|grep _name_|wc -l) - $(dbus list ssconf_basic_|grep _group_|wc -l))) || 0
	#let ONLINE_GET=ONLINE_GET1+ONLINE_GET2+ONLINE_GET3
	ONLINE_GET=$(dbus list ssconf_basic_|grep _group_|wc -l) || 0
	echo_date "本次更新订阅来源 【$group】， 新增节点 $addnum 个，修改 $updatenum 个，删除 $delnum 个；"
	echo_date "现共有自添加 SSR/v2ray/Trojan 节点：$USER_ADD 个。"
	echo_date "现共有订阅 SSR/v2ray/Trojan 节点：$ONLINE_GET 个。"
	echo_date "在线订阅列表更新完成!"	

	# 每次更新后进行初始化
		urllinks=""
		link=""
		decode_link=""
		group=""
}

# 使用订阅链接订阅ssr/v2ray/trojan节点节点
start_online_update(){
	prepare
	rm -rf /tmp/ssr_subscribe_file* >/dev/null 2>&1
	rm -rf /tmp/ssr_subscribe_file_temp1.txt >/dev/null 2>&1
	rm -rf /tmp/all_localservers.txt >/dev/null 2>&1
	rm -rf /tmp/all_subscservers.txt >/dev/null 2>&1
	rm -rf /tmp/all_group_info.txt >/dev/null 2>&1
	rm -rf /tmp/group_info.txt >/dev/null 2>&1
	rm -rf /tmp/multi_*.txt >/dev/null 2>&1
	
	echo_date "收集本地订阅节点信息到临时文件"
	local local_indexs=$(export -p | grep ssconf_basic_ | grep _group_ | cut -d "_" -f4 |cut -d "=" -f1 | sort -n)
	if [ -n "$local_indexs" ]; then
		for local_index in $local_indexs
		do
			# write: server group nu: server_base64 group_base64 remark_base64 node_nu
			echo \
			$(eval echo \$ssconf_basic_server_$local_index | base64_encode) \
			$(eval echo \$ssconf_basic_group_$local_index | base64_encode) \
			$(eval echo \$ssconf_basic_name_$local_index | base64_encode) \
			$local_index \
			>> /tmp/all_localservers.txt
		done
	else
		touch /tmp/all_localservers.txt
	fi
	
	local z=0
	online_url_nu=$(echo $ss_online_links | base64_decode | sed 's/$/\n/' | sed '/^$/d' | wc -l)
	until [ "$z" == "$online_url_nu" ]; do
		let z+=1
		url=$(echo $ss_online_links | base64_decode | awk '{print $1}' | sed -n "$z p" | sed '/^#/d')
		[ -z "$url" ] && continue
		echo_date "==================================================================="
		echo_date "                服务器订阅程序(Shell by stones & sadog)"
		echo_date "==================================================================="
		echo_date "从 $url 获取订阅..."
		addnum=0
		updatenum=0
		delnum=0
		exclude=0
		echo_date "开始更新在线订阅列表..." 
		get_oneline_rule_now "$url"
		case $? in
		0)
			continue
			;;
		2)
			echo_date "无法获取产品信息！请检查你的服务商是否更换了订阅链接！"
			rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
			let DEL_SUBSCRIBE+=1
			sleep 2
			echo_date "退出订阅程序..."
			;;
		3)
			echo_date "该订阅链接不包含任何节点信息！请检查你的服务商是否更换了订阅链接！"
			rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
			let DEL_SUBSCRIBE+=1
			sleep 2
			echo_date "退出订阅程序..."
			;;
		4|5)
			echo_date "订阅地址错误！检测到你输入的订阅地址并不是标准网址格式！"
			rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
			let DEL_SUBSCRIBE+=1
			sleep 2
			echo_date "退出订阅程序..."
			;;
		1|*)
			echo_date "下载订阅失败，请检查你的网络..."
			rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
			let DEL_SUBSCRIBE+=1
			sleep 2
			echo_date "退出订阅程序..."
			;;
		esac
	done

	if [ "$DEL_SUBSCRIBE" == "0" ]; then
		# 尝试删除去掉订阅链接对应的节点
		if [ -f "/tmp/group_info.txt" ]; then
			export -p | grep ssconf_basic_group_ | cut -d "=" -f2 | sort -u | while read local_group; do
			local_group=$(echo $local_group | sed "s/'//g")
				local MATCH=$(cat /tmp/group_info.txt | grep $local_group)
				if [ -z "$MATCH" ]; then
					echo_date "==================================================================="
					echo_date "【$local_group】 节点已经不再订阅，将进行删除..."
					confs_nu=$(export -p | grep ssconf_basic_group_ | cut -d "=" -f1 | cut -d "_" -f4 | grep $local_group)
					for conf_nu in $confs_nu; do
						for item in $PREFIX
						do
							if [ -n "$(eval echo \$${item}${conf_nu})" ]; then
								dbus remove ${item}${conf_nu}
							fi
						done
					done
					# 删除不再订阅节点的group信息
					export -p | grep ss_online_group_ | grep $local_group | cut -d "=" -f1 | cut -d "_" -f4 | while read conf_nu_2; do
						[ -n "$conf_nu_2" ] && dbus remove ss_online_group_$conf_nu_2
					done
				fi
			done
		fi
	else
		echo_date "由于订阅过程有失败，本次不检测需要删除的订阅，以免误伤；下次成功订阅后再进行检测。"
	fi

	# 去除订阅服务器上已经删除的节点
	del_none_exist

	# 节点重新排序
	remove_node_gap

	# 结束
	echo_date "-------------------------------------------------------------------"
	if [ "$SOCKS_FLAG" == "1" ]; then
		ssrlocal=$(ps | grep -w ssr-local | grep -v "grep" | grep -w "23456" | awk '{print $1}')
		if [ -n "$ssrlocal" ]; then 
			echo_date "关闭因订阅临时开启的ssr-local进程:23456端口..."
			kill $ssrlocal  >/dev/null 2>&1
		fi
	elif [ "$SOCKS_FLAG" == "2" ]; then
		sslocal=$(ps | grep -w ss-local | grep -v "grep" | grep -w "23456" | awk '{print $1}')
		if [ -n "$sslocal" ]; then 
			echo_date  "关闭因订阅临时开启ss-local进程:23456端口..."
			kill $sslocal  >/dev/null 2>&1
		fi
	fi
	echo_date "一点点清理工作..."
	rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
	#rm -rf /tmp/all_localservers.txt >/dev/null 2>&1
	#rm -rf /tmp/all_subscservers.txt >/dev/null 2>&1
	#rm -rf /tmp/all_group_info.txt >/dev/null 2>&1
	#rm -rf /tmp/group_info.txt >/dev/null 2>&1
	#rm -rf /tmp/sub_group_info.txt >/dev/null 2>&1
	#rm -rf /tmp/multi_*.txt >/dev/null 2>&1
	echo_date "==================================================================="
	echo_date "所有订阅任务完成，请等待6秒，或者手动关闭本窗口！"
	echo_date "==================================================================="
}

# 添加ss:// ssr:// vmess://离线节点
start_offline_update() {
	echo_date "==================================================================="
	usleep 100000
	echo_date "通过SS/SSR/v2ray/Trojan链接添加节点..."
	rm -rf /tmp/ssr_subscribe_file.txt >/dev/null 2>&1
	rm -rf /tmp/all_localservers.txt >/dev/null 2>&1
	rm -rf /tmp/all_subscservers.txt >/dev/null 2>&1
	rm -rf /tmp/all_group_info.txt >/dev/null 2>&1
	rm -rf /tmp/group_info.txt >/dev/null 2>&1
	ssrlinks=$(echo $ss_base64_links | sed 's/$/\n/'|sed '/^$/d')
	for ssrlink in $ssrlinks
	do
		if [ -n "$ssrlink" ]; then
			if [ -n "$(echo -n "$ssrlink" | grep "ssr://")" ]; then
				echo_date "检测到SSR链接...开始尝试解析..."
				new_ssrlink=$(echo -n "$ssrlink" | sed 's/ssr:\/\///g')
				decode_ssrlink=$(decode_url_link $new_ssrlink)
				get_ssr_node_info "$decode_ssrlink" 2
				add_ssr_nodes_offline
			elif [ -n "$(echo -n "$ssrlink" | grep "vmess://")" ]; then
				echo_date "检测到vmess链接...开始尝试解析..."
				new_v2raylink=$(echo -n "$ssrlink" | sed 's/vmess:\/\///g')
				decode_v2raylink=$(decode_url_link $new_v2raylink)
				decode_v2raylink=$(echo $decode_v2raylink | jq -c .)
				get_v2ray_remote_config "$decode_v2raylink"
				add_v2ray_servers 1
			elif [ -n "$(echo -n "$ssrlink" | grep "ss://")" ]; then
				echo_date "检测到SS链接...开始尝试解析..."
				if [ -n "$(echo -n "$ssrlink" | grep "#")" ]; then
					new_sslink=$(echo -n "$ssrlink" | awk -F'#' '{print $1}' | sed 's/ss:\/\///g')
					new_sslink=$(printf $(echo -n $new_sslink | sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g'))
					ssrlink=$(printf $(echo -n $ssrlink | sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g'))
					#remarks=$(echo -n "$ssrlink" | awk -F'#' '{print $2}')
					remarks=$(echo -n "$ssrlink" | awk -F'#' '{print $2}' | sed 's/[\r\n ]//g')
				else
					new_sslink=$(echo -n "$ssrlink" | sed 's/ss:\/\///g')
					remarks='AddByLink'
				fi
				#decode_sslink=$(decode_url_link $new_sslink)
				get_ss_config "$new_sslink"
				add_ss_servers 1
			elif [ -n "$(echo -n "$ssrlink" | grep "trojan://")" ]; then
				echo_date "检测到 Trojan 链接...开始尝试解析..."
				if [ -n "$(echo -n "$ssrlink" | grep "#")" ];then
					if [ -n "$(echo -n "$ssrlink" | grep "?")" ];then
						new_sslink=$(echo -n "$ssrlink" | awk -F'?' '{print $1}' | sed 's/trojan:\/\///g')	
					else
						new_sslink=$(echo -n "$ssrlink" | awk -F'#' '{print $1}' | sed 's/trojan:\/\///g')
					fi	
					#new_sslink=$(echo -n "$ssrlink" | awk -F'#' '{print $1}' | sed 's/trojan:\/\///g')
					
					#remarks=$(echo -n "$ssrlink" | awk -F'#' '{print $2}')
					if [ -n "$(echo -n "$ssrlink" | grep "%")" ];then
						remarks=$(echo -n "$ssrlink" | awk -F'#' '{print $2}' | sed 's/[\r\n ]//g')
						remarks=$(printf $(echo -n $remarks| sed 's/\\/\\\\/g;s/\(%\)\([0-9a-fA-F][0-9a-fA-F]\)/\\x\2/g')"\n")
					else
						remarks=$(echo -n "$ssrlink" | awk -F'#' '{print $2}' | sed 's/[\r\n ]//g')
					fi
					echo "【$remarks】"
				else
					new_sslink=$(echo -n "$ssrlink" | sed 's/trojan:\/\///g')
					remarks='AddByLink'
				fi
				get_trojan_config "$new_sslink"
				add_trojan_servers 1
			fi
		fi
		dbus remove ss_base64_links
	done
	echo_date "==================================================================="
}

case $2 in
0)
	# 删除所有节点
	set_lock
	echo " " > $LOG_FILE
	http_response "$1"
	remove_all_node | tee -a $LOG_FILE
	echo XU6J03M6 | tee -a $LOG_FILE
	unset_lock
	;;
1)
	# 删除所有订阅节点
	set_lock
	echo " " > $LOG_FILE
	http_response "$1"
	remove_sub_node | tee -a $LOG_FILE
	echo XU6J03M6 | tee -a $LOG_FILE
	unset_lock
	;;
2)
	# 保存订阅设置但是不订阅
	set_lock
	echo " " > $LOG_FILE
	http_response "$1"
	local_groups=$(export -p | grep ssconf_basic_ | grep _group_ | cut -d "=" -f2 | sort -u | wc -l)
	online_group=$(echo $ss_online_links | base64_decode | sed 's/$/\n/' | sed '/^$/d' | wc -l)
	echo_date "保存订阅节点成功，现共有 $online_group 组订阅来源，当前节点列表内已经订阅了 $local_groups 组..." | tee -a $LOG_FILE
	sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "$ss_basic_node_update" = "1" ]; then
		if [ "$ss_basic_node_update_day" = "7" ]; then
			cru a ssnodeupdate "0 $ss_basic_node_update_hr * * * /jffs/softcenter/scripts/ss_online_update.sh fancyss 3"
			echo_date "设置自动更新订阅服务在每天 $ss_basic_node_update_hr 点。" | tee -a $LOG_FILE
		else
			cru a ssnodeupdate "0 $ss_basic_node_update_hr * * $ss_basic_node_update_day /jffs/softcenter/scripts/ss_online_update.sh fancyss 3"
			echo_date "设置自动更新订阅服务在星期 $ss_basic_node_update_day 的 $ss_basic_node_update_hr 点。" | tee -a $LOG_FILE
		fi
	else
		echo_date "关闭自动更新订阅服务！" | tee -a $LOG_FILE
		sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
	echo XU6J03M6 | tee -a $LOG_FILE
	unset_lock
	;;
3)
	# 使用订阅链接订阅ssr/v2ray/trojan节点
	set_lock
	echo " " > $LOG_FILE
	http_response "$1"
	echo_date "开始订阅" | tee -a $LOG_FILE
	start_online_update | tee -a $LOG_FILE
	echo XU6J03M6 | tee -a $LOG_FILE
	unset_lock
	;;
4)
	# 添加ss:// ssr:// vmess:// trojan://离线节点
	set_lock
	echo " " > $LOG_FILE
	http_response "$1"
	start_offline_update | tee -a $LOG_FILE
	echo XU6J03M6 | tee -a $LOG_FILE
	unset_lock
	;;
5)
	prepare
	;;
esac

