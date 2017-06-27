# -*- coding: utf-8 -*-
# vim: ft=sls
{% from "mysql/defaults.yaml" import rawmap with context %}

include:
  - mysql.repo
  - mysql.python
  - mysql.custom_version

{% set mysql = salt['grains.filter_by'](rawmap, grain='os', merge=salt['pillar.get']('mysql:lookup')) %}
{% set mysql_root_user = salt['pillar.get']('mysql:server:root_user', 'root') %}
{% set mysql_root_password = salt['pillar.get']('mysql:server:root_password', salt['random.get_str'](32)) %}
{% set mysql_host = salt['pillar.get']('mysql:server:host', 'localhost') %}
{% set defaults_extra_file = salt['pillar.get']('mysql:defaults_extra_file', mysql.defaults_extra_file) %}

mysql_debconf_utils:
  pkg.installed:
    - name: {{ mysql.debconf_utils }}

mysql_debconf:
  debconf.set:
    - name: {{ mysql.pkg_prefix }}
    - data:
        '{{ mysql.pkg_prefix }}-server/root_password': {'type': 'password', 'value': '{{ mysql_root_password }}'}
        '{{ mysql.pkg_prefix }}-server/root_password_again': {'type': 'password', 'value': '{{ mysql_root_password }}'}
        '{{ mysql.pkg_prefix }}-server/start_on_boot': {'type': 'boolean', 'value': 'true'}
    - require_in:
      - pkg:  percona-server-pkg
    - require:
      - pkg: {{ mysql.debconf_utils }}

percona-server-pkg:
{# We want to install a custom version and it's not in repository #}
{%- if mysql.version is defined and salt['cmd.retcode']('apt-cache madison ' ~ mysql.pkg_prefix ~ '-' ~ mysql.major_version ~ ' | grep -qP \'(^|\s)\K' ~ mysql.pkg_prefix ~ '-' ~ mysql.major_version ~ '(?=\s|$)\' | grep -qP \'(^|\s)\K' ~ mysql.version ~ '-1(?=\s|$)\'', python_shell=True) == 1 %}
  pkg.installed:
    - sources:
      - {{ mysql.pkg_prefix }}-server-{{ mysql.major_version }}: /tmp/percona/{{ mysql.pkg_prefix }}-server-{{ mysql.version_suffix_w_major }}
      {%- if mysql.major_version == '5.6' %} {# Percona removed packages like percona-server-server-5.6_5.6.36-82.0-1.trusty_amd64.deb in 5.7 release #}
      - {{ mysql.pkg_prefix }}-server: /tmp/percona/{{ mysql.pkg_prefix }}-server_{{ mysql.version_suffix }}
      {% endif %}
    - require:
      - sls: mysql.custom_version
        # Download all Percona software and install from standalone .deb files
        #wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-2.4.3/binary/debian/trusty/x86_64/percona-xtrabackup-24_2.4.3-1.trusty_amd64.deb
        #wget https://www.percona.com/downloads/percona-toolkit/2.2.18/deb/percona-toolkit_2.2.18-1_all.deb
        #wget https://www.percona.com/downloads/percona-monitoring-plugins/1.1.6/percona-nagios-plugins_1.1.6-1_all.deb
{% else %}
  pkg.installed:
    - name: {{ mysql.pkg_prefix }}-server-{{ mysql.major_version }}
    - require:
      - debconf: mysql_debconf
{% endif %} {# if mysql.version is defined... #}

mysql_root_password:
  mysql_user:
    - present
    - name: '{{ mysql_root_user }}'
    - password: '{{ mysql_root_password }}'
    - connection_host: '{{ mysql_host }}'
    - connection_default_file: {{ defaults_extra_file }}
    - connection_charset: utf8
    - saltenv:
      - LC_ALL: "en_US.utf8"
    - require:
      - service: mysqld
      - pkg: mysql_python

root_my_cnf:
  file.managed:
    - name: /root/.my.cnf
    - template: jinja
    - source: salt://mysql/files/root_my.cnf
    - user: root
    - group: root
    - mode: 600
    - context:
       mysql_root_user: '{{ mysql_root_user }}'
       mysql_root_password: '{{ mysql_root_password }}'
    - require:
      - mysql_user: mysql_root_password

{% for host in ['localhost', 'localhost.localdomain', salt['grains.get']('fqdn')] %}
mysql_delete_anonymous_user_{{ host }}:
  mysql_user:
    - absent
    - host: {{ host or "''" }}
    - name: ''
    - connection_host: '{{ mysql_host }}'
    - connection_user: '{{ mysql_root_user }}'
    {% if mysql_root_password %}
    - connection_pass: '{{ mysql_root_password }}'
    {% endif %}
    - connection_charset: utf8
    - require:
      - service: mysqld
      - pkg: mysql_python
      {%- if mysql_root_user and mysql_root_password %}
      - mysql_user: mysql_root_password
      {%- endif %}
{% endfor %}

mysql_tzinfo_to_sql:
  cmd.run:
    - name: mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql --defaults-extra-file=/root/.my.cnf mysql
    - unless: test $(mysql --defaults-extra-file=/root/.my.cnf mysql -sN --execute="select count(*) from time_zone;") -gt 0
    - require:
      - service: mysqld
      - file: root_my_cnf

mysqld:
  service.running:
    - name: {{ mysql.service }}
    - enable: True
    - watch:
      - pkg: percona-server-pkg
