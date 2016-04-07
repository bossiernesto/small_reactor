require 'thread'
require_relative '../src/orderedarray'
require_relative '../src/reporter'
require_relative '../src/abstract'
require_relative '../src/reactor_exceptions'
require_relative '../src/timeable'
require_relative '../src/timers'

DEFAULT_QUANTUM = 10 #Time in milliseconds

module Reactor

  class BaseEvent
    attr_accessor :status, :valid_statuses, :callbacks

    def initialize_status
      self.status = :clean
      self.valid_statuses = [:clean, :dirty]
    end

    def is_dirty?
      self.status == :dirty
    end

    def change_status(status)
      unless self.valid_statuses.include? status
        raise ReactorException, 'Invalid status'
      end
      self.status = status
    end

    def get_callback
      self.callbacks[0]
    end

    def callbacks
      @callbacks ||= []
    end

    def has_callbacks?
      self.callbacks.length > 0
    end

    def remove_last_callback
      self.callbacks.delete self.callbacks[-1]
    end

    def add_callback(wait_if_attached, &callback)
      unless wait_if_attached
        self.callbacks = [callback]
        self.change_status :dirty
        return
      end
      self.callbacks << callback
    end
  end

  class TaskEvent < BaseEvent
    attr_accessor :block

    def initialize(&block)
      self.callbacks = [block]
    end

    def execute
      for callback in self.callbacks
        callback.call
      end
    end

  end

  class TimedEvent < TaskEvent
    include Timeable

    def initialize(timer=nil, block_timer=false, &block)
      if block_timer
        self.initialize_timers timer, true, &block
      else
        self.initialize_timers timer, false
        self.callbacks = [block]
      end
    end

    def execute
      unless self.all_timers_comply?
        return
      end

      super
      self.timers.each { |timer| timer.consume }
      self.timers.sort
    end
  end

  class IOEvent < BaseEvent
    attr_accessor :io, :status, :valid_statuses

    def initialize(io, &callback)
      self.io = io
      self.callbacks = [callback] if callback
      self.initialize_status
    end

  end

  class EventHandlerManager

    attr_accessor :mode, :events, :debug, :io_allowed

    def initialize(mode, debug=false, io_allowed=true)
      self.debug = debug
      self.mode = mode
      self.io_allowed = io_allowed
      self.events = []
    end

    def is_io_included(io)
      self.events.each do |event|
        begin
          if event.io == io
            return event
          end
        rescue NoMethodError
          #Don't do anything just let it pass, log the error on debug
          Reporter.report_error "Event #{event} of type #{event.class} has no knowledge of IO Events."
        end
      end
      nil
    end

    def remove_all_events
      self.events = []
    end

    def attach(_wait_if_attached=true, &callback)
      self.events << (TaskEvent.new(&callback))
    end

    def attach_io(io, wait_if_attached=true, &callback)
      raise EventHandlerException, 'Can not attach an io event to an unallowed io event manager' unless self.io_allowed

      event = self.is_io_included io
      unless event.nil?
        #Add the callback to an existing event
        event.add_callback wait_if_attached, &callback
        return
      end
      self.events << (IOEvent.new io, &callback)
    end

    def detach(event, force)
      if !force && event.has_callbacks?
        event.remove_last_callback
        return
      end

      self.events.delete(event)
      self.change_status :dirty

    end

    def get_events_io
      dirty_events = []
      events = []
      self.events.each do |event|
        if event.is_dirty?
          dirty_events << event.io
        else
          events << event.io
        end
      end
      return events, dirty_events
    end


    def get_event(io)
      self.is_io_included io
    end

  end

  class Dispatcher
    include Logger

    attr_accessor :running, :handler_manager_read, :handler_manager_write, :handler_manager_error, :handler_manager_tasks, :on_attach, :on_detach, :ios, :quantum, :debug


    def initialize(debug=false, quantum=DEFAULT_QUANTUM)
      self.debug = debug
      #State for manager lists
      self.handler_manager_read = EventHandlerManager.new :read, self.debug
      self.handler_manager_write = EventHandlerManager.new :write, self.debug
      self.handler_manager_error = EventHandlerManager.new :error, self.debug
      self.handler_manager_tasks = EventHandlerManager.new :tasks, self.debug, false

      #process queue
      self.ios= []

      #Other state for reactor dispatcher
      self.running = true
      self.quantum = quantum

      #Set up the listeners
      self.on_attach = []
      self.on_detach = []
    end

    def is_running?
      running
    end

    def change_reactor_quantum(new_timeout)
      unless new_timeout.is_a? Integer
        msg = "Can not set a non integer value as a valid quantum time. Leaving the quantum in #{self.quantum}"
        self.report_error msg
      end
      self.quantum = new_timeout
      self.report_system "Changing quantum of reactor to #{new_timeout} milliseconds"
    end

    def run
      self.report_system 'Starting main reactor loop'
      yield self if block_given?
      begin
        while is_running?
          run_cycle
        end
      rescue SystemExit, Interrupt
        self.report_system 'Exiting from main reactor loop.'
        exit
      end
    end

    def run_cycle
      read_ios, _dirty_read_ios = get_events_for :read
      write_ios, _dirty_write_ios = get_events_for :write
      error_ios, _dirty_error_ios = get_events_for :error

      event = IO.select(read_ios, write_ios, error_ios, 0.001 * self.quantum)
      if event
        fire_events :read, event[0]
        fire_events :write, event[1]
        fire_events :error, event[2]
      end
      fire_task_events
    end

    def attach_task(handler, wait_if_attached=true, &callback)
      handler.attach wait_if_attached, &callback
    end

    def attach_io(handler, mode, io, wait_if_attached = true, &callback)
      handler.attach_io io, wait_if_attached, &callback
      self.process_on_attach mode, io if self.has_listeners self.on_attach
    end

    def attach_handler(mode, io=nil, wait_if_attached = true, &callback)
      if callback.nil?
        msg = 'A callback block should be passed to the attach_handler.'
        self.report_error msg
        raise ReactorException, msg
      end

      handler_manager = get_handler_manager mode

      if mode_is_task(mode)
        self.report_system "Attaching callback to tasks"
        self.attach_task handler_manager, wait_if_attached, &callback
      else
        self.report_system "Attaching callback to io #{io}"
        self.attach_io handler_manager, mode, io, wait_if_attached, &callback
      end
    end

    def detach_handler(mode, io, force=False)
      handler_manager = get_handler_manager mode
      handler = handler_manager.is_io_included io
      unless handler
        #The io doesn't exits anymore
        return
      end

      self.report_system "Detaching handler #{handler}"
      handler_manager.detach handler, force

      self.process_on_detach mode, io if self.has_listeners self.on_detach
    end

    def detach_all_handlers(mode)
      handler_manager = get_handler_manager mode
      self.report_system "Detaching all handler from mode #{mode}"
      handler_manager.remove_all_events
    end

    def get_handler_manager(mode)
      check_valid_mode mode
      self.instance_variable_get("@handler_manager_#{mode}")
    end

    def get_events_for(mode)
      handler_manager = get_handler_manager mode
      handler_manager.get_events_io
    end

    def fire_task_events
      handler_manager = get_handler_manager :tasks
      handler_manager.events.each do |event|
        event.execute if event.is_a? TaskEvent
      end
    end

    def fire_events mode, ios
      handler_manager = get_handler_manager mode
      ios.each do |io|
        event = handler_manager.get_event io
        self.ios << [io, event.get_callback]
      end
      self.process_ios
    end

    def process_ios
      ios.each { |io| self.process_io io }.clear
    end

    def process_io(io)
      io[1].call io[0], self
    end

    def check_valid_mode(mode)
      unless [:read, :write, :error, :tasks].include? mode
        msg = "Mode #{mode} is not a valid one."
        self.report_error msg
        raise ReactorException, msg
      end
    end

    def mode_is_task(mode)
      mode == :tasks
    end

    #Methods for managing the listeners
    def has_listeners(listener_list)
      listener_list.length > 0
    end

    def add_detach_listener(name, run_once=false, &block)
      listener = Listener.new name, run_once, &block
      self.on_detach << listener
    end

    def add_attach_listener(name, run_once=false, &block)
      listener = Listener.new name, run_once, &block
      self.on_attach << listener
    end

    def remove_all_attach_listeners
      self.on_attach.clear
    end

    def remove_all_detach_listeners
      self.on_detach.clear
    end

    def abstract_process_listeners(listener_list, mode, io=nil)
      listener_list.each do |listener|
        listener.call mode, io
        listener_list.delete listener if listener.run_once?
      end

    end

    def process_on_attach(mode, io=nil)
      self.abstract_process_listeners self.on_attach, mode, io
    end


    def process_on_detach(mode, io=nil)
      self.abstract_process_listeners self.on_detach, mode, io
    end

  end

  class Listener
    include Logger
    attr_accessor :callback, :name, :run_once

    def initialize(name, run_once, &block)
      self.name = name
      self.run_once = run_once
      self.callback = block
    end

    def check_block_arity &block
      unless block.parameters.length == 2
        msg = "Block #{block} has not 2 parameters. Listener blocks must respect the following contract proc {|mode, io| ...}"
        self.report_error msg
        raise ListenerException msg
      end
    end

    def run_once?
      self.run_once
    end

  end

end


