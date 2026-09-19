Developer$ xtool new Hello
Creating package: Hello
Creating Package.swift
Creating xtool.yml
Creating .gitignore
Creating .bsp/xtool.json
Creating Sources/Hello/HelloApp.swift
Creating Sources/Hello/ContentView.swift

Finished generating project Hello.

Developer$ cd Hello
Hello$ ls -la
-rw-rw-r--  1 user user  187 .gitignore
drwxrwxr-x  2 user user 4096 .bsp
-rw-rw-r--  1 user user  463 Package.swift
drwxrwxr-x  3 user user 4096 Sources
-rw-rw-r--  1 user user   39 xtool.yml

Hello$ cat xtool.yml
version: 1
bundleID: com.example.Hello

Hello$ cat .bsp/xtool.json
{
    "name": "xtool",
    ...
    "argv": ["/usr/bin/env", "xtool", "dev", "build-server"]
}
