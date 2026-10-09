# 1  创建字符串
str1 = "Hello Python"
print(str1)

# 2  通过下标获取字符
str1 = "Python"

print(str1[0])
print(str1[1])
print(str1[2])

# 3 字符串长度

str1 = "Python"

print(len(str1))


# 4 字符串查找
# find()

str1 = "Hello Python"

print(str1.find("Python"))


# 5 字符串替换
# replace()

str1 = "Hello Python"

str2 = str1.replace("Python", "World")

print(str2)


# 6 字符串分割
# split()

str1 = "苹果,香蕉,西瓜"

result = str1.split(",")

print(result)


# ==============================
# 七、字符串连接
# ==============================

list1 = ["苹果", "香蕉", "西瓜"]

result = "-".join(list1)

print(result)


# ==============================
# 八、字符串去除空格
# strip()
# ==============================

str1 = "   Python   "

print(str1.strip())


# ==============================
# 九、判断字符串是否以某内容开头
# startswith()
# ==============================

str1 = "Python学习"

print(str1.startswith("Python"))


# ==============================
# 十、判断字符串是否以某内容结尾
# endswith()
# ==============================

str1 = "hello.py"

print(str1.endswith(".py"))


# ==============================
# 十一、字符串切片
# ==============================

str1 = "Python"

print(str1[0:3])
print(str1[2:5])


# ==============================
# 十二、字符串遍历
# ==============================

str1 = "Python"

for i in str1:
    print(i)


# ==============================
# 十三、字符串大小写
# ==============================

str1 = "Python"

print(str1.upper())
print(str1.lower())


# ==============================
# 十四、统计字符出现次数
# count()
# ==============================

str1 = "hello"

print(str1.count("l"))


# ==============================
# 十五、字符串综合案例
# ==============================

text = "Python是一门非常容易学习的编程语言"

print("长度:", len(text))
print("是否包含Python:", "Python" in text)
print("出现次数:", text.count("编程"))
