---
title: MongoDB Driver
layout: sidebar
nav_menu: default-nav
sidebar_menu: design-sidebar
---
# Design

## The core classes

This project did not start by sitting back and design things first. I Can't tell if Paweł Pabian did, it was a good and obvious setup when I took over. But later when things went complex using concurrency and all that, it was necessary to make some drawings to show how things are connected and how it could change for performance. After some work, it crystallized into the following which is the core of the machinery;

{% assign url = site.baseurl | append: "/images/uml/mdb02.svg" %}
![url]( {{ url }} )

The users application uses the **Client**, **Database**, **Collection** and **Cursor** objects the most. First the application initializes a **Client** by providing a uri which describes the servers to access with some options. After that, it creates the **Database** object. Most commands can be given using the method `.run-command()` on the **Database** object which in turn uses **Collection** to run `.find()` to get its task done. The type of commands are those which return a single document. When commands are needed which return multiple documents, the application must create a **Collection** to use the `.find()` method itself. `.find()` then, returns a **Cursor** object which can be iterated over to get all documents.

**ServerPool** is made singleton to make several objects able to select a server. The **SocketPool** is like that for the same reason (more than one server needs it). **Monitor** is created only once and then made to run in a thread. Its main task is to get information from the mongodb servers. **Client** objects must start the **Monitor** as its first task which is only done once of course.


## Interactions client and server objects

At the creation of the Client object, there are a lot of actions happening to get all parts ready for the next user task. Below is an interaction of a **Client**, **Server** and **Monitor** shown followed with cleaning up a **Client**;

{% assign url = site.baseurl | append: "/images/uml/CSM-interact.svg" %}
![url]( {{ url }} )

Most of the time, a client interacts only with one server when it is 'Stand alone' as they say. In this diagram, a server set is retrieved from the server and then made available in the topology. This happens when there is a replica server set which can contain multiple types of servers.

The different colors white and turquoise is to show different threads where the white one is the users applications thread.

Communication between these objects is mainly done by emitting messages in one object to observers in possibly several other objects.


## Interactions using run-command

{% assign url = site.baseurl | append: "/images/uml/DBIO-interact01.svg" %}
![url]( {{ url }} )


## Interactions using find

{% assign url = site.baseurl | append: "/images/uml/DBIO-interact02.svg" %}
![url]( {{ url }} )