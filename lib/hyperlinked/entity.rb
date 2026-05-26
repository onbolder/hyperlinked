# frozen_string_literal: true

require "hyperlinked/relation"
require "forwardable"
require "weakref"

module Hyperlinked
  module EnumerableEntity
    include Enumerable

    def each(&block)
      entities.get(:items).each(&block)
    end

    def full_set
      page = self

      Enumerator.new do |yielder|
        loop do
          page.each { |item| yielder.yield(item) }
          raise StopIteration unless page.has_rel?(:next)
          page = page.next

          if page.has?(:errors) # && page.errors.first.messages.first['cannot be higher'] # reached last page
            yielder.yield(nil, page.errors) # yield a nil value so caller can stop gracefully
            raise StopIteration
          end
        end
      end
    end
  end

  module PropertyEnumerable
    include Enumerable

    def each(&block)
      properties.each(&block)
    end

    def to_h
      to_hash
    end
  end

  class Entity

    CURIE_EXP = /(.+):(.+)/.freeze
    CURIES_REL = 'curies'.freeze
    SPECIAL_PROP_EXP = /^_.+/.freeze

    def self.wrap(obj, client: nil, top: nil)
      case obj
      when Hash
        new(obj, client, top: top)
      when Array
        EntityArray.new(obj, client, top)
      else
        obj
      end
    end

    def initialize(attrs, client, top: self)
      @attrs = attrs.is_a?(Hash) ? attrs : {}
      @client = client ? WeakRef.new(client) : nil
      @top = top

      extend EnumerableEntity if iterable?
    end

    def to_hash
      @attrs
    end

    alias_method :to_h, :to_hash

    def as_json(opts = {})
      to_hash
    end

    def dig(*keys)
      @attrs.dig(*keys)
    end

    def [](key)
      has_property?(key) ? properties.get(key) : entities.get(key)
    end

    alias_method :try, :[]

    def has?(prop_name)
      has_property?(prop_name) || has_entity?(prop_name) || has_rel?(prop_name)
    end

    def can?(rel_name)
      has_rel?(rel_name)
    end

    def inspect
      %(#<#{self.class.name} properties: [#{properties.keys.join(', ')}] relations: [#{rels.keys.join(', ')}] entities: [#{entities.keys.join(', ')}]>)
    end

    def properties
      @properties ||= PropertySet.new(attrs.select { |k,v| !(k =~ SPECIAL_PROP_EXP) }, client, top)
    end

    alias_method :props, :properties

    def entities
      @entities ||= EntitySet.new(attrs.fetch('_embedded', {}), client, top)
    end

    def relations
      @relations ||= RelationSet.new(attrs.fetch('_links', {}), client, top, curies)
    end

    alias_method :rels, :relations

    def links
      @links ||= attrs.fetch('_links', {})
    end

    def method_missing(name, *args, &block)
      if !block_given?
        if has_property?(name)
          properties.get(name)
        elsif has_entity?(name)
          entities.get(name)
        elsif has_rel?(name)
          rels.get(name).run(*args)
        else
          super
        end
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      has?(method_name)
    end

    def has_property?(name)
      properties.has?(name)
    end

    def has_entity?(name)
      entities.has?(name)
    end

    def has_rel?(name)
      rels.has?(name)
    end

    private
    attr_reader :top, :attrs

    def client
      return nil unless @client

      @client.__getobj__
    rescue WeakRef::RefError
      raise 'BooticClient: the client for this entity has been garbage collected. ' +
            'Hold a reference to your strategy/client for as long as you need to follow links.'
    end

    def curies
      @curies ||= top.links.fetch('curies', [])
    end

    def iterable?
      entities.has?(:items) && entities.get(:items).is_a?(EntityArray)
    end

    class EntityArray
      include Enumerable
      extend Forwardable

      def initialize(items, client, top)
        @items = items
        @client, @top = client, top
        @cache = {}
      end

      def_instance_delegators :@items, :count, :size, :length, :empty?

      def inspect
        %(#<#{self.class.name} length: #{length}]>)
      end

      # def first
      #   self[0]
      # end

      def last
        self[length-1]
      end

      def [](index)
        @cache[index] ||= Entity.wrap(@items[index], client: @client, top: @top)
      end

      def get(index)
        self[index]
      end

      def each(&block)
        return enum_for(:each) unless block_given?
        length.times { |i| yield self[i] }
      end
    end

    class PropertySet
      include Enumerable

      def initialize(attrs, client = nil, top = nil)
        @attrs = stringify_keys(attrs || {})
        @client, @top = client, top
        @cache = {}
      end

      # overwrite Enumerable#count because some Entities have this prop
      def count
        get('count') or raise NoMethodError, "undefined method `count` for #{self.inspect}"
      end

      def keys
        @keys ||= @attrs.keys
      end

      def has?(key)
        has_key?(key.to_s) || !!has_boolean?(key.to_s)
      end

      def inspect
        %(#<#{self.class.name} properties: [#{keys.join(', ')}]>)
      end

      def to_hash
        @attrs
      end

      alias_method :to_h, :to_hash

      def as_json(opts = {})
        to_hash
      end

      def dig(*keys)
        @attrs.dig(*keys)
      end

      def [](key)
        get(key)
      end

      def get(key)
        if !has_key?(key.to_s) and found = has_boolean?(key.to_s)
          key = found
        end

        @cache[key.to_s] ||= wrap(@attrs[key.to_s])
      end

      def each(&block)
        keys.each { |k| yield k, get(k) }
      end

      private

      def wrap(value)
        case value
        when Hash
          if @client
            entity = Entity.wrap(value, client: @client, top: @top || value)
            entity.extend(PropertyEnumerable)
            entity
          else
            PropertySet.new(value)
          end
        when Array
          value.map { |e| wrap(e) }
        else
          value
        end
      end

      def method_missing(name, *args, &block)
        if has?(name.to_s)
          get(name)
        else
          super
        end
      end

      def has_key?(key)
        @attrs.has_key?(key)
      end

      def has_boolean?(key)
        if key[key.size-1] == '?' and key = key.chomp('?')
          return key if is_boolean?(key)
        end
      end

      def is_boolean?(key)
        @attrs[key].is_a?(TrueClass) || @attrs[key].is_a?(FalseClass)
      end

      # def all
      #   keys.map { |k| get(key) }
      # end

      def stringify_keys(hash)
        hash.inject({}) { |memo,(k,v)| memo[k.to_s] = v; memo }
      end
    end

    class EntitySet < PropertySet
      def initialize(attrs, client, top)
        super(attrs)
        @client, @top = client, top
      end

      def inspect
        %(#<#{self.class.name} entities: [#{keys.join(', ')}]>)
      end

      def get(key)
        @cache[key.to_s] ||= Entity.wrap(@attrs[key.to_s], client: @client, top: @top)
      end
    end

    class RelationSet < EntitySet
      def initialize(attrs, client, top, curies)
        super(attrs, client, top)
        @curies = curies
      end

      def inspect
        %(#<#{self.class.name} relations: [#{keys.join(', ')}]>)
      end

      def has?(key)
        return true if super

        key = key.to_s
        @attrs.keys.any? { |k| k =~ CURIE_EXP && $2 == key }
      end

      def get(key)
        return if key.to_s == CURIES_REL

        @cache[key.to_s] ||= begin
          key = key.to_s
          obj = @attrs[key]

          if obj.nil?
            matching_key = @attrs.keys.find { |k| k =~ CURIE_EXP && $2 == key }
            if matching_key
              obj = @attrs[matching_key]
              ns = $1
              if curie = @curies.find { |c| c['name'] == ns }
                obj['docs'] = Relation.expand(curie['href'], rel: key)
              end
            end
          end

          Relation.new(obj, @client)
        end
      end

    end

  end
end
