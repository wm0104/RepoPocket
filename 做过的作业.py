
xitong = """
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# 1. 添加学生信息 2. 修改学生信息 3. 删除学生信息 4. 查询学生信息 5. 列出所有学生 6. 统计班级成绩 7.  退出系统 #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
"""

xinxi = {}
while True:
    print(xitong)
    caozuo = input("请输入要执行的操作(1-7): ")
    match caozuo:
        case "1": # 添加学生信息
            name = input("请输入姓名")
            yw = input("请输入语文成绩")
            sx = input("请输入数学成绩")
            yy = input("请输入英语成绩")
            if name in xinxi:
                print("学生已经存在, 请重新输入")
            else:
                xinxi[name] = {"yw": yw, "sx": sx, "yy": yy}
                print(f"添加{name}成功")


        case "2": # 修改学生信息
            name = input("请输入要修改的学生姓名")
            if name not in xinxi:
                print("学生不存在, 请重新输入")
                continue
            else:
                yw = input("请输入要修改的语文成绩")
                sx = input("请输入要修改的数学成绩")
                yy = input("请输入要修改的英语成绩")
                xinxi[name] = {"yw": yw, "sx": sx, "yy": yy}
                print(f"修改{name}成功")

        case "3": # 删除学生信息
            name = input("请输入要删除的学生姓名")
            if name not in xinxi:
                print("学生不存在, 请重新输入")
            else:
                del xinxi[name]
                print(f"删除{name}成功")

        case "4": # 查询学生信息
            name = input("请输入要查询的学生信息")
            if name not in xinxi:
                print("找不到学生, 请重新输入")
            else:
                value = xinxi[name]
                print(f"学生名字:{name} | 语文成绩:{value["yw"]} | 数学成绩:{value["sx"]} | 英语成绩:{value["yy"]} ")

        case "5": # 列出所有学生, 并遍历学生信息
           pass

        case "6": # 统计成绩
          pass



        case "7":
            print("拜拜")
            break
        case _:
            print("操作不支持")