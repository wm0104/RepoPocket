# 案例2：
# 猜数字游戏
# 1. 系统随机生成一个随机数
# 2. 用户根据提示猜数字，并将所猜的数字输入系统
# 3. 如果猜错，系统给出提示是猜大了，还是猜小了，然后继续输入猜的数字
# 4. 如果猜对，系统自动退出，游戏结束
import random
suiji = random.randint(1,100)

while True:
    shuzi = int(input("请输入一个数字"))
    if shuzi > suiji:
        print("猜大了继续猜")
    elif shuzi < suiji:
        print("猜小了继续猜")
    else:
        print("恭喜你猜对了游戏结束")
        break
print("随机数是", suiji)




# 需求
# 1 到 1000 之间所有 5 的倍数的数字累加之和
# 需求2
# 字符串akiwksjakdiklowiqaamnvbamvaxnsjdsjkakxjd中有几个a和k

# 案例1
he = 0
for i in range(1,1001):
    if i % 5 == 0:
         he += i
print(f"1到1000之间所有5的倍数的数字累加之和是{he}")

# 案例2
zfc = "akiwksjakdiklowiqaamnvbamvaxnsjdsjkakxjd"
s1 = 0
s2 = 0
for i in zfc:
 if i == "a":
     s1 += 1
 elif i == "b":
     s2 += 1
print(f"有{s1}个a, {s2}个b")

