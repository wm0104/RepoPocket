# 集合 set
from xml.dom.minidom import ProcessingInstruction
from xml.dom.pulldom import SAX2DOM
"""
s1 = {2 , 1 ,3 ,4 ,5 ,6 ,7 ,8 ,9 ,10 ,1 , 2 , 3 , 4 }
print(s1)
print(type(s1))

s1 = {100 ,200,300 ,400 ,500 ,600 ,700 , 800}
print(s1)

s1.add(900)
print(s1)

s1.remove(900)
print(s1)

s2 = s1.pop()
print(s2)
print(s1)

s1.clear()
print(s1)

s2 = {"A", "B", "C", "D", "E", "X", "Y"}
s3 = {"C", "E", "Y", "Z"}

# difference() : 求两个集合的差集（存在于第一个集合，但不存在于第二个集合）
print(s2.difference(s3))
print(s3.difference(s2))

# # union() : 求两个集合的并集(两个集合共有的)
print(s2.union(s3))
print(s3.union(s2))

# intersection() : 求两个集合的交集(合并并且去重)
print(s2.intersection(s3))
print(s2.intersection(s3))


print('---'*20)



print(s2 - s3) #差集
print(s3 - s2) #差集

print(s2 & s3) #交集
print(s3 & s2) #交集

print(s2 | s3) #并集
print(s3 | s2) #并集
"""
#

# 选修足球学生名单
football_set = {"王林", "曾牛", "徐立国", "遁天", "天运子", "韩立", "厉飞雨", "乌丑", "紫灵"}
# 选修篮球学生名单
basketball_set = {"张铁", "墨居仁", "王林", "姜老道", "曾牛", "王蝉", "韩立", "天运子", "李化元", "厉飞雨", "云雾"}
# 选修法语学生名单
french_set = {"许木", "王卓", "十三", "虎咆", "姜老道", "天运子", "厉飞雨", "韩立", "曾牛"}
# 选修艺术学生名单
art_set = {"遁天", "天运子", "韩立", "虎咆", "姜老道", "紫灵"}

# 1 找出同时选修了法语和艺术的学生
s1 = french_set & art_set
print("同时选修了法语和艺术的学生",s1)
# 3 找出选修了足球，但是没有选修篮球的学生
s2 = football_set - basketball_set
print("选修了足球，但是没有选修篮球的学生",s2)
# 4 统计每一个学生选修的课程数量
s3 = [*football_set, *basketball_set, *french_set, *art_set]
for i in set(s3):
    print(f"{i}选修了{s3.count(i)}节课")