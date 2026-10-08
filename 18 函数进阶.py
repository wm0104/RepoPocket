# 函数  -  变量的作用域
num = 100 # 全局变量
# 全局变量不管在函数内还是函数外都能访问到
# 局部变量只能在函数内部使用

# 定义函数
def s1_list(y,h):
    he = y + h

    num = 1000 # 局部变量num
    print("num" , num)
    return he

print(s1_list(29 ,30))

print("num" , num) # 函数外 全局num 100

print("-----" *15)
# 定义函数
def s1_list(y,h):
    he = y + h

    global num  # global 跟上函数名(意思是我要修改为全局变量)
    num = 1000 # 局部变量num
    print("num" , num)

    return he

print(s1_list(29 ,30))

print("num" , num) # 函数外 全局num 1000

# 1. 什么是局部变量，全局变量？
# 在函数内部定义的变量就是局部变量，函数外声明的变量是全局变量。

# 2. global关键字的作用？
# 在函数内部使用，声明接下来要使用的是全局变量，语法：global xxx

# 3. 注意事项
# 尽量避免在函数中使用全局变量，因为会使代码难以维护和调试
# 考虑使用函数参数和返回值来传递数据，而不是依赖全局变量
# global主要用在程序的状态、配置和计数器等场景中