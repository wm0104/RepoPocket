"""
# 元组基本操作 - tuple ---> 元素可以重复,有序,不可修改
# 定义
t1 = (80, 95, 78, 50, 76, 80, 85, 20)

print(t1)
print(type(t1))

# 索引访问
print(t1[0])
print(t1[-1])

# 切片
print(t1[0:5:1])

# count() 统计元素的个数
print(t1.count(80))

# index() 获取元素的索引(第一个元素的位置)
print(t1.index(80))

# 注意点:如果定义单元素的元组,单个元素之后需要加上逗号,比如 (100,)
t2 = ()
print(t2)
print(type(t2))
"""

# tuple 组包与解包 
# 组包操作
# t1 = (5, 7, 9, 10, 2, 23, 12)
# t2 = 5, 7, 9, 10, 2, 23, 12
#
# print(t1)
# print(t2)
#
# # 解包操作
# # 基础解包(变量数量与容器的元素个数一致)
# a,b,c,d,e,f,g = t1
# print(a,b,c,d,e,f,g)
#
# # * 扩展解包 (* 收集剩余的所有元素，封装列表list中)
# first,second,*other,last = t1
# print(first,second)
# print(other)
# print(last)
#
# *other,last2,last1 = t1
# print(other)
# print(last2)
# print(last1)
# ###
#
#
# a = 10
# b = 20
# a,b = b,a
# print(a)
# print(b)

##
# 小结
# 组包与解包
# 组包(Packing):将多个值合并到一个容器(元组、列表)中。
# 解包(Unpacking):将容器中的元素分别赋值给多个变量。
# 在元组解包时,*表示收集剩余的所有元素,允许我们处理不确定数量的元素
#
#
# 1. 元组有什么特点?
#    · 元素可以重复
#    · 有序
#    · 不可修改(只读)
# 2. 元组的两个查询方法?
#    · count():统计指定元素的数量
#    · index():获取指定元素的索引,如果该元素不存在将报错
# 3. 元组使用注意事项?
#    · 定义单元素元组时,需要在结尾加上逗号,比如 ('A',)


# 根据如下提供的学生成绩单,完成如下需求:
# 1. 计算每个学生的总分、各科平均分,然后一并输出出来。
# 2. 统计各科成绩的最低分、最高分、平均分,并输出。
# 3. 查找成绩优秀(平均分大于90)的学生,并输出。
print("学号\t\t姓名\t\t语文\t\t数学\t\t英语\t\t总分\t\t平均分")
cj = (
    ("S001", "王林", 85, 92, 78),
    ("S002", "李慕婉", 92, 88, 95),
    ("S003", "十三", 78, 85, 82),
    ("S004", "曾牛", 88, 79, 91),
    ("S005", "周轶", 95, 96, 89),
    ("S006", "王卓", 76, 82, 77),
    ("S007", "红蝶", 89, 91, 94),
    ("S008", "徐立国", 75, 69, 82),
    ("S009", "许木", 86, 89, 98),
    ("S010", "遁天", 66, 59, 72)
 )
# # 1. 计算每个学生的总分、各科平均分,然后一并输出出来
# 方式1
for i in cj:
    zf = i[2] + i[3] +i[4]
    pjf = zf / 3
    print(f" {i[0]} \t{i[1]}  \t  {i[2]}   \t  {i[3]}   \t  {i[4]}  \t  {zf}  \t  {pjf:.1f}")

print('--'*25) # 分隔25(--)

#方式2
for ID , name , yuwen , shuxue , yingyu in cj:
    zf = yuwen + shuxue + yingyu
    pjf = zf / 3
    print(f" {ID} \t{name}  \t  {yuwen}  \t  {shuxue}   \t  {yingyu} \t  {zf}  \t  {pjf:.1f}")

print('--'*25) # 分隔25(--)
# 计算各科的最低分 平均分 最高分
yuwen = [i[2] for i in cj]
shuxue = [i[3] for i in cj]
yingyu = [i[4] for i in cj]
print(f"语文最高分是: {max(yuwen)} 最低分是{min(yuwen)} 平均分是{sum(yuwen)/len(yuwen)}")
print(f"数学最高分是: {max(shuxue)} 最低分是{min(shuxue)} 平均分是{sum(shuxue)/len(shuxue)}")
print(f"英语最高分是: {max(yingyu)} 最低分是{min(yingyu)} 平均分是{sum(yingyu)/len(yingyu)}")

print('--'*25) # 分隔25(--)

print('平均分大于90的学生名单')
#把平均分大于90分的学生输出出来
for ID , name , yuwen , shuxue ,yingyu  in cj:
    zf = yuwen + shuxue + yingyu
    pjf = zf / 3
    if pjf > 90:
        print(f"{ID} {name} {pjf:.1f}")

