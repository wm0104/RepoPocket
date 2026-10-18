# ==============================
# 16 函数基础
# ==============================


# 一、定义和调用函数

def hello():
    print("你好")


hello()


# ==============================
# 二、函数参数
# ==============================

def hello2(name):
    print("你好", name)


hello2("张三")
hello2("李四")


# ==============================
# 三、多个参数
# ==============================

def add(a, b):
    return a + b


result = add(10, 20)

print(result)


# ==============================
# 四、return返回值
# ==============================

def max_num(a, b):

    if a > b:
        return a
    else:
        return b


result = max_num(10, 20)

print("最大值:", result)


# ==============================
# 五、函数返回多个值
# ==============================

def test():
    return 10, 20, 30


a, b, c = test()

print(a)
print(b)
print(c)


# ==============================
# 六、函数 + 列表
# ==============================

def score_info(score):

    max_score = max(score)
    min_score = min(score)
    avg_score = sum(score) / len(score)

    return max_score, min_score, avg_score


score = [78, 56, 92, 43, 65, 89, 51, 37, 74, 60]

zdf, zxf, avg = score_info(score)

print("最高分:", zdf)
print("最低分:", zxf)
print("平均分:", avg)


# ==============================
# 七、函数 + for循环
# ==============================

def count_pass(score):

    count = 0

    for i in score:
        if i >= 60:
            count = count + 1

    return count


print("及格人数:", count_pass(score))
print() # 测试
