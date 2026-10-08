# 案例
# 正确的用户名和密码为admin/666888、zhangsan/123456、taoge/888666
#
# 输入用户名和密码进行登录，直到登录成功，程序结束运行；如果登录失败，则继续输入用户名和密码进行登录
#
# 输入的用户名和密码不能为空！
#
# 登录成功：输出"登录成功，进入B站首页~"
#
# 登录失败：输出"用户名或密码错误，请重新输入！"
# continue{束当前循环，直接进入下一轮循环} , break{跳出循环}只能出现在循环中

# while True:
#     # 1. 接收输入的用户名和密码
#     username = input("请输入正确的用户名：")
#     password = input("请输入正确的密码：")
#
#     # 2. 校验：输入的用户名和密码不能为空！
#     if username == "" or password == "":
#         print("输入的用户名和密码不能为空！请重新输入")
#         continue  # 结束当前循环，直接进入下一轮循环
#
#     # 3. 判断用户名和密码的正确性，执行登录操作
#     if username == "admin" and password == "666888":
#         print("登录成功，进入B站首页~")
#         break  # 跳出循环
#
#     elif username == "zhangsan" and password == "123456":
#         print("登录成功，进入B站首页~")
#         break  # 跳出循环
#
#     elif username == "taoge" and password == "888666":
#         print("登录成功，进入B站首页~")
#         break  # 跳出循环
#
#     else:
#         print("用户名或密码错误，请重新输入！")


# 练习
# 根据需求完成如下练习
# 需求：
# 用户名密码登录，正确的用户名和密码为wjc/621390、cjw/123456、zyx/66666，
# 5次登录机会，输入错误五次，不允许再操作了。
cuowu = 5
while cuowu > 0:
     zhanghao = input("请输入账号：")
     mima = input("请输入密码：")  # 用字符串，不用int()
     if zhanghao == "wjc" and mima == "621390":  # 修正密码
         print("登录成功")
         break
     elif zhanghao == "cjw" and mima == "123456":
         print("登录成功")
         break
     elif zhanghao == "zyx" and mima == "66666":
         print("登录成功")
         break
     else:
         cuowu -= 1
         if cuowu > 0:
             print(f"密码错误，请重试！还剩 {cuowu} 次机会")
         else:
             print("密码错误已达5次，账号已被锁定，不允许再操作了！")
