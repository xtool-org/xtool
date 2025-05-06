Developer$ supersign dev new Hello
Creating package: Hello
Creating Package.swift
Creating supersign.yml
Creating .gitignore
Creating .sourcekit-lsp/config.json
Creating Sources/Hello/HelloApp.swift
Creating Sources/Hello/ContentView.swift

Finished generating project Hello.

Developer$ cd Hello
Hello$ ls -la
-rw-rw-r--  1 user user  187 .gitignore
drwxrwxr-x  2 user user 4096 .sourcekit-lsp
-rw-rw-r--  1 user user  463 Package.swift
drwxrwxr-x  3 user user 4096 Sources
drwxrwxr-x  4 user user 4096 supersign
-rw-rw-r--  1 user user   39 supersign.yml

Hello$ cat supersign.yml
version: 1
bundleID: com.example.Hello
