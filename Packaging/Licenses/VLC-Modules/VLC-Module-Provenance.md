# VLC模块内头文件来源说明

日期：2026-10-15。本文件由Audilse项目撰写，说明实际采用的VLC transcode与spatializer模块内两份头文件来源。它不是上游许可原件，不在原源文件中添加授权，也不是整个框架的法律保证。独立来源审查已通过，报告随本文件保留。

## transcode.h

官方VLC提交`25fd8c34e3140671c166bc4e4903cd4a425ce916`（2009-11-24）将单一transcode.c拆为同一transcode目标的多个源文件和内部头transcode.h；头自该拆分起没有独立许可段。

官方提交`2416d7d14e36ddd36a793d8245c6bdfc09ae45e3`（2013-11-20）明确按相应贡献者授权将几乎全部stream_out/mux模块重授为LGPL-2.1-or-later，并列出duplicate/rtp例外；transcode不在例外中，该提交实际更新其相关源授权。这是本项目记录该内部头属于transcode模块授权范围的依据，不是自动继承邻文件许可。

当前头相对官方固定基线的两个venc字段来自保留的上游`0020-transcode-add-support-for-mutliple-venc-parameters.patch`。原补丁From身份为`ba4f8b9f08685eaeabb43d704dc26035f0fdab66`；本地补丁应用后的提交身份为`e7eebdb8aa4df92f11e2d20c5a319b91a9ae05c2`，两者不混称同一个官方commit。

## revmodel.hpp

保留的Jezar Freeverb原作者文本重刊（`sinshu/freeverb`固定提交`cfcea55553fb59ac57ebf2a237f72cad4296f2b0`）包含原readme与Components/revmodel.hpp的Public Domain说明。随附`Freeverb-original-readme.txt`是该原文；重刊者不被冒称原作者或原作者站点。

VLC官方提交`c701929d30cec6cf69092928a624625f279701d3`引入Biodun Osunkunle的spatializer适配。它对原Freeverb头存在实际修改，不能把原Public Domain说明扩为VLC适配全部贡献也属Public Domain。

官方提交`fef270581f736d4f6289a77cb115195241ed691d`（2012-11-06）明确按相应贡献者授权重授播放模块（含audio filters）为LGPL-2.1-or-later，并列明例外；spatializer不在例外中，带适配者署名的spatializer.cpp授权头实际更新。由原Freeverb来源及VLC模块范围重授权共同支持当前头的来源解释。

## 配套材料

应用`Licenses/VLCKit-LGPL-2.1.txt`保留完整LGPL文本。随项目`build/vlc-source-delivery/license-audit/vlc-header-provenance/`保留官方提交/历史JSON、原重刊来源身份、固定与实际源码、精确diff、上游补丁、Applicability及独立审查。原头没有单独许可块这一事实未被掩盖。

这三份VLC-Modules说明资源不计入123份VLC-Contrib通知。已排除插件或ssh2的旧授权问题不被重新引入；其它组件仍按实际来源适用表记录。
