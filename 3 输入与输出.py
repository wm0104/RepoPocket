# 1. 基本输出
print("Hello World")

# 2. 输出多个内容（用逗号分隔，默认空格隔开）
print("姓名:", "张三", "年龄:", 18)
# 输出：姓名: 张三 年龄: 18

# 3. sep 参数 - 自定义分隔符
print("苹果", "香蕉", "橘子", sep="、")
# 输出：苹果、香蕉、橘子

print("2026", "09", "08", sep="-")
# 输出：2026-09-08

# 4. end 参数 - 自定义结尾（默认是换行 \n）
print("第一行", end="")
print("第二行")          # 输出：第一行第二行

print("Loading", end="...")
print("完成")            # 输出：Loading...完成

# 5. 输出变量
name = "小明"
score = 95.5
print(name, "的成绩是", score)
# 输出：小明 的成绩是 95.5

# 6. f-string 格式化输出（Python 3.6+，推荐）
print(f"{name}的成绩是{score}分")
# 输出：小明的成绩是95.5分

# 7. format() 方法
print("{}的成绩是{}分".format(name, score))
# 输出：小明的成绩是95.5分

# 8. % 格式化（老方法）
print("%s的成绩是%.1f分" % (name, score))
# 输出：小明的成绩是95.5分

#-----------------------------------

# 1. 基本输入
name = input("请输入你的名字：")
print(f"你好，{name}！")

# 2. 输入数字（需要类型转换）
age = input("请输入你的年龄：")    # 输入：18
print(type(age))                  # <class 'str'>

# 转换为整数
age_int = int(age)                # 转为 int
print(f"明年你{age_int + 1}岁了")

# 3. 一行输入多个值（用 split 分割）
# 输入：张三 18 95.5
data = input("请输入姓名 年龄 成绩：").split()
name = data[0]
age = int(data[1])
score = float(data[2])
print(f"姓名：{name}，年龄：{age}，成绩：{score}")

# 4. 更简洁的多变量赋值
# 输入：张三 18 95.5
name, age, score = input("请输入姓名 年龄 成绩：").split()
age = int(age)
score = float(score)
print(f"姓名：{name}，年龄：{age}，成绩：{score}")

# 5. 输入多个数字（列表推导式）
# 输入：1 2 3 4 5
nums = [int(x) for x in input("请输入多个数字：").split()]
print(nums)          # [1, 2, 3, 4, 5]
print(sum(nums))     # 15